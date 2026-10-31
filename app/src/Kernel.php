<?php

namespace App;

use Symfony\Bundle\FrameworkBundle\Kernel\MicroKernelTrait;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\Filesystem\Filesystem;
use Symfony\Component\HttpFoundation\File\Exception\FileException;
use Symfony\Component\HttpFoundation\File\UploadedFile;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpFoundation\StreamedResponse;
use Symfony\Component\HttpKernel\Event\TerminateEvent;
use Symfony\Component\HttpKernel\Kernel as BaseKernel;
use Symfony\Component\HttpKernel\KernelEvents;
use Symfony\Component\Routing\Attribute\Route;

/**
 * Controllers answer without touching the request body or the uploaded file.
 * A kernel.terminate listener then records what it can still read, keyed by the X-Probe-Id header.
 */
final class Kernel extends BaseKernel implements EventSubscriberInterface
{
    use MicroKernelTrait;

    public static function getSubscribedEvents(): array
    {
        return [KernelEvents::TERMINATE => 'recordTermination'];
    }

    protected function configureContainer(ContainerConfigurator $container): void
    {
        $container->extension('framework', ['secret' => 'reproducer']);
    }

    #[Route('/submit', methods: ['POST', 'PUT'])]
    public function submit(): Response
    {
        return new Response("accepted\n");
    }

    #[Route('/stream-failure', methods: ['GET'])]
    public function streamFailure(): StreamedResponse
    {
        return new StreamedResponse(static function (): void {
            echo "partial\n";

            throw new \RuntimeException('Streaming the response failed.');
        });
    }

    #[Route('/terminations/{id}', methods: ['GET'], requirements: ['id' => '[a-z0-9-]+'])]
    public function termination(string $id): Response
    {
        $file = $this->terminationFile($id);

        return is_file($file)
            ? new Response(file_get_contents($file), 200, ['Content-Type' => 'application/json'])
            : new JsonResponse(['error' => 'kernel.terminate has not run for this request'], 404);
    }

    public function recordTermination(TerminateEvent $event): void
    {
        $request = $event->getRequest();
        if (!preg_match('/^[a-z0-9-]+$/', $id = (string) $request->headers->get('X-Probe-Id'))) {
            return;
        }

        usleep(1000 * (int) $request->headers->get('X-Terminate-Delay-Ms', '0'));

        $record = ['body_bytes' => \strlen($request->getContent())];

        $upload = $request->files->get('upload');
        if ($upload instanceof UploadedFile) {
            // is_file() could answer from the stat cache, which the UploadedFile constructor filled for this path.
            $contents = @file_get_contents($upload->getPathname());
            $record['upload_bytes'] = false === $contents ? 'unreadable' : \strlen($contents);

            try {
                $upload->move($this->getProjectDir().'/var/uploads', $id);
                $record['upload_move'] = 'moved';
            } catch (FileException $e) {
                $record['upload_move'] = 'FileException';
            }
        }

        (new Filesystem())->dumpFile($this->terminationFile($id), json_encode($record));
    }

    private function terminationFile(string $id): string
    {
        return $this->getProjectDir().'/var/terminations/'.$id.'.json';
    }
}
