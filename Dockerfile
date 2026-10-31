# syntax=docker/dockerfile:1

FROM composer:2.11.1 AS vendor
WORKDIR /app
COPY app/composer.json app/composer.lock ./
RUN composer install --no-dev --no-interaction --no-progress --prefer-dist --no-autoloader
COPY app/ ./
RUN composer dump-autoload --no-dev --classmap-authoritative

FROM vendor AS vendor-67679
COPY frankenphp-worker-runner-67679.patch /tmp/
RUN patch -p5 --forward -d vendor/symfony/runtime < /tmp/frankenphp-worker-runner-67679.patch

FROM vendor-67679 AS vendor-followup
COPY frankenphp-worker-runner-followup.patch /tmp/
RUN patch -p5 --forward -d vendor/symfony/runtime < /tmp/frankenphp-worker-runner-followup.patch

FROM dunglas/frankenphp:1.13.4-php8.5.12-trixie@sha256:c8abcc7925f16b1431f139d0410abe8f48db3fd862bacb646b05a4413337106a AS frankenphp
ENV APP_ENV=prod APP_DEBUG=0
WORKDIR /app

FROM frankenphp AS stock
COPY --from=vendor /app /app

FROM frankenphp AS pr67679
COPY --from=vendor-67679 /app /app

FROM frankenphp AS followup
COPY --from=vendor-followup /app /app
