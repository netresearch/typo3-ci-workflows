<?php

/*
 * Fails when config/rector/rector.php uses a set-list constant that Rector
 * marks @deprecated or that does not exist.
 *
 * A deprecated set constant is one Rector removes later, and its removal kills
 * the Rector job of every consumer at once (that happened with STRICT_BOOLEANS
 * in Rector 2.6.0). The check reads the file with nikic/php-parser, so every
 * way PHP can name a class (imports, aliases, grouped imports, fully
 * qualified names) resolves the same way PHP resolves it. Comments are not
 * code, so the constants they name are not checked.
 *
 * Usage: php Build/Scripts/check-rector-set-constants.php [file]
 */

declare(strict_types=1);

use PhpParser\Node;
use PhpParser\Node\Expr\ClassConstFetch;
use PhpParser\Node\Identifier;
use PhpParser\Node\Name;
use PhpParser\NodeFinder;
use PhpParser\NodeTraverser;
use PhpParser\NodeVisitor\NameResolver;
use PhpParser\ParserFactory;

require_once __DIR__ . '/../../vendor/autoload.php';

$file = $argv[1] ?? __DIR__ . '/../../config/rector/rector.php';
$code = file_get_contents($file);
if ($code === false) {
    fwrite(STDERR, "{$file}: cannot read the file" . PHP_EOL);
    exit(2);
}

$ast       = (new ParserFactory())->createForHostVersion()->parse($code) ?? [];
$traverser = new NodeTraverser(new NameResolver());
$ast       = $traverser->traverse($ast);

/** @var list<ClassConstFetch> $fetches */
$fetches = (new NodeFinder())->find(
    $ast,
    static fn (Node $node): bool => $node instanceof ClassConstFetch
        && $node->class instanceof Name
        && $node->name instanceof Identifier
        && $node->name->toString() !== 'class',
);

$checked = 0;
foreach ($fetches as $fetch) {
    $class    = $fetch->class->toString();
    $constant = $fetch->name->toString();
    if (!str_ends_with($class, 'SetList')) {
        continue;
    }

    try {
        $doc = (new ReflectionClassConstant($class, $constant))->getDocComment();
    } catch (ReflectionException $e) {
        fwrite(STDERR, "{$file}:{$fetch->getStartLine()}: {$class}::{$constant} does not exist: {$e->getMessage()}" . PHP_EOL);
        exit(1);
    }

    ++$checked;
    if ($doc !== false && str_contains($doc, '@deprecated')) {
        fwrite(STDERR, "{$file}:{$fetch->getStartLine()}: {$class}::{$constant} is deprecated" . PHP_EOL);
        exit(1);
    }
}

if ($checked === 0) {
    fwrite(STDERR, "{$file}: no set-list constant found" . PHP_EOL);
    exit(1);
}

echo "rector set constants: {$checked} checked, none deprecated" . PHP_EOL;
