<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\OptOut\Controller;

use Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\OptOut\Command\ImportCommand;

final class ImportController
{
    public function use(ImportCommand $dependency): void {}
}
