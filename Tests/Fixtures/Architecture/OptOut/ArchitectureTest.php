<?php

declare(strict_types=1);

namespace Netresearch\Typo3CiWorkflows\Tests\Fixtures\Architecture\OptOut;

use Netresearch\Typo3CiWorkflows\Architecture\LayerRules;
use Netresearch\Typo3CiWorkflows\Architecture\Layers;

final class ArchitectureTest
{
    use LayerRules {
        testLayerControllerDoesNotDependOnCommand as private;
    }

    private function layers(): Layers
    {
        return Layers::below('Netresearch\\Typo3CiWorkflows\\Tests\\Fixtures\\Architecture\\OptOut');
    }
}
