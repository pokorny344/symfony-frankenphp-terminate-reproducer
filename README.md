# kernel.terminate under the FrankenPHP worker runner

In FrankenPHP worker mode, the `Symfony\Component\Runtime\Runner\FrankenPhpWorkerRunner` of `symfony/runtime` v7.4.22 calls `$kernel->terminate()` after `frankenphp_handle_request()` has returned.
By then FrankenPHP has already shut the request down (`frankenphp_worker_request_shutdown()` calls `sapi_deactivate()`), so `kernel.terminate` listeners can no longer use uploaded files, or read a POST body that was not read while handling the request.
Outside worker mode the same listeners work, because `HttpKernelRunner` terminates after the response was flushed but before PHP tears the request down.

[symfony/symfony#67679](https://github.com/symfony/symfony/pull/67679), merged into 7.4 as `9d123e3dba9`, terminates the kernel inside the request callback, after `Response::send()`.
When `Response::send()` throws, the kernel then does not terminate at all.
The follow-up [symfony/symfony#67730](https://github.com/symfony/symfony/pull/67730) terminates it in a `finally` block.

This repository reproduces both problems with a minimal Symfony 7.4 application and shows the behaviour with the follow-up.

## Run it

Requirements: Docker with Compose v2, bash and curl.

```sh
./reproduce.sh
```

The script builds three images from the same application and starts four FrankenPHP servers:

| Service | Port | How the app runs |
| --- | --- | --- |
| `classic` | 8081 | `frankenphp php-server`, no worker, so `HttpKernelRunner` |
| `worker` | 8082 | `frankenphp php-server --worker`, stock `symfony/runtime` v7.4.22 |
| `worker-67679` | 8083 | the same worker, with the runner of #67679 |
| `worker-followup` | 8084 | the same worker, with the runner of #67679 and the follow-up |

It then sends the same five requests to each server:

1. A 4096-byte JSON `POST /submit`.
2. The same body as `PUT /submit`.
3. A `POST /submit` with an 8192-byte file upload.
4. A `POST /submit` whose `kernel.terminate` listener sleeps for two seconds, timed by curl.
5. A `GET /stream-failure`, whose `StreamedResponse` throws after sending its first bytes, with the same two-second sleep and timing.

The controllers never read the body or the upload.
The `kernel.terminate` listener in [`app/src/Kernel.php`](app/src/Kernel.php) records what it can still use: the length of `Request::getContent()`, the uploaded file's contents and the outcome of `UploadedFile::move()`.
The script reads those records back and prints them.

It exits with 0 only when the stock worker runner shows the problem, the runner of #67679 shows the regression, and the follow-up runner differs from both and matches the non-worker runner.
`KEEP=1 ./reproduce.sh` leaves the containers running afterwards.

## Result

Recorded on 1 November 2026, three runs on macOS arm64 (Docker Desktop, Docker 29.8.2, Compose 5.5.0) and three on Ubuntu x86_64 (Docker 29.9.2, Compose 5.6.1).
Every run printed the same values.
Only the response times differ: well under a tenth of a second when the client did not wait for the listener, and just over two seconds when it did.

```text
FrankenPHP v1.13.4 PHP 8.5.12 Caddy v2.11.7 h1:yj0Y4fYZGPkSvibBJ1sTWE33xC0fxztVyXEW5iIdUT4=
symfony/runtime v7.4.22

What kernel.terminate saw                    classic          worker           worker-67679     worker-followup
runner (FrankenPhpWorkerRunner.php sha1)     HttpKernelRunner bb5523e8         e918c69d         6ff53769
POST body (4096 bytes sent)                  4096             0                4096             4096
PUT body (4096 bytes sent)                   0                0                0                0
uploaded file (8192 bytes sent)              8192             unreadable       8192             8192
UploadedFile::move()                         moved            FileException    moved            moved
response time, terminate sleeps 2000ms (s)   0.001944         0.001651         0.001232         0.001585
same, when the StreamedResponse throws (s)   2.012008         0.001691         0.001688         2.004183
terminate ran after StreamedResponse threw   yes              yes              no               yes

BUG REPRODUCED: with the stock worker runner, kernel.terminate cannot read the POST body or the uploaded file.
REGRESSION REPRODUCED: with the runner of #67679, kernel.terminate can read them, but does not run when sending the response throws.
FIX VERIFIED: with the follow-up runner, kernel.terminate sees what it sees outside worker mode, and the client waits for it only when sending the response fails, as outside worker mode with debug off.
```

With the stock worker runner, `Request::getContent()` returns an empty string during `kernel.terminate`.
The uploaded file has already been deleted, and `UploadedFile::move()` throws a `FileException` because `is_uploaded_file()` no longer knows the file.

With the runner of #67679, `kernel.terminate` sees the same request as it does outside worker mode.
Termination still does not delay a successful response: `Response::send()` calls `fastcgi_finish_request()`, which FrankenPHP provides, so the client already has the full response when the listeners run.
When sending the response throws, though, the exception leaves the request callback before the kernel terminates, so `kernel.terminate` never runs for that request.
The stock worker runner still terminates it, after FrankenPHP has reported the exception and ended the request.

With the follow-up, the kernel also terminates when sending the response throws.
`fastcgi_finish_request()` is then never reached, so the client waits for the listeners.
It waits outside worker mode too, where the exception handler terminates the kernel before PHP ends the request.
The servers run with `APP_DEBUG=0`.
With the runtime's `debug` option on, `HttpKernelRunner` does not call `fastcgi_finish_request()`, so outside worker mode the client also waits for the listeners after a successful response.
Without the Dotenv component, which this application does not install, `APP_DEBUG` does not set that option, but `APP_RUNTIME_OPTIONS='{"debug":true}'` does.

A PUT body that nobody read before the response was sent is empty during `kernel.terminate` in every mode, and so are PATCH and DELETE bodies and a POST body without a `Content-Type` header.
When the request starts, PHP reads only a POST body that has a `Content-Type` header; it reads any other body only when the application asks for it, and FrankenPHP no longer provides the body once the response has been sent.
A body that the application read while handling the request stays available in every mode, because `Request` keeps the content it has read.
Neither runner change affects that.

In worker mode, `is_file($upload->getPathname())` can still return `true` during `kernel.terminate` after the file was deleted.
PHP's stat cache keeps the result of the check that `UploadedFile`'s constructor made, and FrankenPHP does not clear that cache between worker requests.
The listener therefore reads the file instead of calling `is_file()`.

## The patches

Both patches change only `Runner/FrankenPhpWorkerRunner.php`.

[`frankenphp-worker-runner-67679.patch`](frankenphp-worker-runner-67679.patch) is #67679:

- The kernel terminates inside the `frankenphp_handle_request()` callback, after `Response::send()` has flushed the response, while the request is still alive.
- An exception thrown by a termination listener is kept and rethrown after `frankenphp_handle_request()` returns.
  FrankenPHP handles an exception that escapes the callback itself and keeps the worker running, so rethrowing it outside the callback keeps the stock behaviour: the exception escapes `run()` and ends the worker script.

[`frankenphp-worker-runner-followup.patch`](frankenphp-worker-runner-followup.patch) is the follow-up, applied on top:

- Termination runs from a `finally` block, so it also happens when sending the response throws.

In a Symfony clone, `git diff v7.4.22 9d123e3dba9 -- src/Symfony/Component/Runtime/Runner/FrankenPhpWorkerRunner.php` prints the first patch.
After `git fetch origin pull/67730/head`, `git diff 9d123e3dba9 2b94f3130d0 -- src/Symfony/Component/Runtime/Runner/FrankenPhpWorkerRunner.php` prints the second.
The `stock` image keeps `vendor/symfony/runtime/Runner/FrankenPhpWorkerRunner.php` from v7.4.22 (sha1 `bb5523e8`).
The `pr67679` image applies the first patch with `patch -p5` (sha1 `e918c69d` afterwards), and the `followup` image applies both (sha1 `6ff53769`).

## Versions

| Component | Version |
| --- | --- |
| FrankenPHP image | `dunglas/frankenphp:1.13.4-php8.5.12-trixie@sha256:c8abcc7925f16b1431f139d0410abe8f48db3fd862bacb646b05a4413337106a` (multi-platform index) |
| FrankenPHP, PHP, Caddy | 1.13.4, 8.5.12 ZTS, 2.11.7 |
| Symfony | 7.4.22, except `event-dispatcher` 7.4.17 and `filesystem` 7.4.21, which have not changed since; locked in [`app/composer.lock`](app/composer.lock) |
| Composer image used for `composer install` | `composer:2.11.1` |

## Files

- [`app/src/Kernel.php`](app/src/Kernel.php): the whole application, a `MicroKernelTrait` kernel with three routes and the `kernel.terminate` listener.
- [`app/public/index.php`](app/public/index.php): the standard Symfony Runtime front controller.
- [`Dockerfile`](Dockerfile): the `stock`, `pr67679` and `followup` images.
- [`compose.yaml`](compose.yaml): the four servers.
- [`reproduce.sh`](reproduce.sh): sends the requests, prints the table and checks the expected outcome.
