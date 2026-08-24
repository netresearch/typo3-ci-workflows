#!/usr/bin/env bash
#
# e2e-provision.sh — bring up a TYPO3 instance for an e2e run
#
# Sourced by runTests.sh when `-s e2e` needs an environment rather than an
# address. It is the generic half of what used to live in one extension's
# 1775-line e2e.sh: MariaDB, a composer-installed TYPO3, PHP-FPM, Apache, and
# the checks that each of them actually came up. Nothing here knows any
# extension.
#
# The four things that ARE extension-specific come from runTests.conf. All are
# optional; an extension that defines none gets a bare TYPO3 with no site.
#
#   e2e_provision_packages
#       Prints the composer packages to require, space-separated. Called with
#       the variant in ${E2E_VARIANT} and the TYPO3 constraint in
#       ${E2E_TYPO3_CONSTRAINT}, so a package whose major tracks the TYPO3
#       major can pick its own. The extension under test is required from a
#       path repository before this and does not belong in the list.
#
#   e2e_provision_typoscript
#       Writes ts-constants.typoscript and/or ts-setup.typoscript into
#       ${E2E_SCRIPTS}. Their contents land in the root sys_template. Variant
#       differences (a TS import that only resolves when the extension
#       providing it is installed) belong here, which is why this is a
#       function and not a static file.
#
#   e2e_provision_site_dependencies
#       Prints the `dependencies:` entries for the site configuration, one
#       per line, already indented by two spaces.
#
#   e2e_provision_seed
#       Runs after TYPO3 is installed and the schema exists. Gets a container
#       with the instance at /var/www/html and the extension at /extension,
#       and is where demo content goes. Receives ${E2E_ROOT} and
#       ${E2E_SCRIPTS}.
#
# Requires from runTests.sh: CONTAINER_BIN, CONTAINER_COMMON_PARAMS, NETWORK,
# SUFFIX, CI_PARAMS, IMAGE_PHP, IMAGE_APACHE, ROOT_DIR and wait_for.

# Remove a directory the e2e containers wrote into. They run as root, so a
# plain `rm -rf` hits "Permission denied" on their files: it fails quietly, the
# directory survives, and the next `composer create-project` aborts with
# "Project directory is not empty". A fresh CI runner never sees this; a
# developer's second run always does. Delete from inside a container, which
# runs as the same user that created the files.
e2e_remove_container_owned_dir() {
    local target="${1}"
    [[ -d "${target}" ]] || return 0
    rm -rf "${target}" 2>/dev/null || true
    if [[ -d "${target}" ]]; then
        ${CONTAINER_BIN} run --rm -v "${target}:/target" ${IMAGE_PHP} \
            sh -c 'rm -rf /target/* /target/.[!.]* 2>/dev/null; true' >/dev/null 2>&1 || true
        rmdir "${target}" 2>/dev/null || true
    fi
}

# The package name of the extension under test, from its own composer.json.
# Not guessed from the directory name: the two differ often enough
# (t3x-rte_ckeditor_image ships netresearch/rte-ckeditor-image) that guessing
# would fail on most of the fleet.
e2e_package_name() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.name // empty' "${ROOT_DIR}/composer.json" 2>/dev/null
    else
        sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "${ROOT_DIR}/composer.json" 2>/dev/null | head -n1
    fi
    # Printing nothing is a valid answer — the caller checks for an empty name
    # and reports it — so a failed read must not make the function itself fail.
    return 0
}

# Bring up the instance. On success TYPO3_BASE_URL names the Apache container
# and the caller can run its tests against it. On failure this returns
# non-zero at the step that failed, having said which one — the whole point of
# the exit checks below is that a later symptom never becomes the headline.
e2e_provision() {
    E2E_ROOT="${ROOT_DIR}/.Build/e2e-typo3"
    E2E_SCRIPTS="${ROOT_DIR}/.Build/e2e-scripts"
    E2E_VARIANT="${E2E_VARIANT:-default}"

    echo "Setting up E2E environment (variant: ${E2E_VARIANT})..."
    e2e_remove_container_owned_dir "${E2E_ROOT}"
    rm -rf "${E2E_SCRIPTS}"
    mkdir -p "${E2E_ROOT}" "${E2E_SCRIPTS}"

    # The helper scripts are written on the host and mounted read-only. They
    # are not inlined into the container command because quoting PHP inside a
    # double-quoted `bash -c` is how the original grew its escaping bugs.
    cat > "${E2E_SCRIPTS}/additional.php" << 'ADDITIONAL_EOF'
<?php
return [
    'BE' => ['debug' => true],
    'FE' => [
        'debug' => true,
        'debugExceptionHandler' => \TYPO3\CMS\Core\Error\DebugExceptionHandler::class,
    ],
    'SYS' => [
        'devIPmask' => '*',
        'displayErrors' => 1,
        'exceptionalErrors' => E_WARNING | E_USER_ERROR | E_USER_WARNING | E_USER_NOTICE,
        'trustedHostsPattern' => '.*',
        'debugExceptionHandler' => \TYPO3\CMS\Core\Error\DebugExceptionHandler::class,
        'productionExceptionHandler' => \TYPO3\CMS\Core\Error\DebugExceptionHandler::class,
    ],
];
ADDITIONAL_EOF

    cat > "${E2E_SCRIPTS}/db-setup.php" << 'DBSETUP_EOF'
<?php
// Connect to MariaDB
$pdo = new PDO(
    'mysql:host=mariadb-e2e;port=3306;dbname=e2e_test',
    'root',
    'root',
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);
$now = time();

// Debug: List existing tables to verify schema was created by TYPO3's database:updateschema
echo "Checking existing tables...\n";
$tables = $pdo->query("SHOW TABLES")->fetchAll(PDO::FETCH_COLUMN);
echo "Found " . count($tables) . " tables\n";
if (count($tables) < 10) {
    echo "WARNING: Expected many tables from database:updateschema, but found only " . count($tables) . "\n";
}

// Ensure default file storage has correct configuration
// TYPO3 uses FlexForm XML format for sys_file_storage.configuration
// TYPO3 setup may create uid=1 with empty configuration — we must fix it
// CRITICAL: is_public = 1 is required for click-to-enlarge to work (imageLinkWrap)
$storageConfig = '<?xml version="1.0" encoding="utf-8" standalone="yes" ?><T3FlexForms><data><sheet index="sDEF"><language index="lDEF"><field index="basePath"><value index="vDEF">fileadmin/</value></field><field index="pathType"><value index="vDEF">relative</value></field></language></sheet></data></T3FlexForms>';
$pdo->prepare("INSERT INTO sys_file_storage (uid, name, driver, configuration, is_default, is_public, tstamp, crdate) VALUES (1, 'fileadmin', 'Local', ?, 1, 1, ?, ?) ON DUPLICATE KEY UPDATE configuration = VALUES(configuration), is_public = 1")
    ->execute([$storageConfig, $now, $now]);
echo "Default file storage ensured (FlexForm XML with basePath)\n";

// Insert root page
$pdo->exec("INSERT IGNORE INTO pages (uid, pid, title, slug, doktype, is_siteroot, hidden, deleted, tstamp, crdate) VALUES (1, 0, 'Home', '/', 1, 1, 0, 0, $now, $now)");
echo "Pages record inserted\n";

// Insert error handling test page (child of root) — isolates edge-case CEs from main page
$pdo->exec("INSERT IGNORE INTO pages (uid, pid, title, slug, doktype, is_siteroot, hidden, deleted, tstamp, crdate) VALUES (2, 1, 'Error Handling Tests', '/error-handling-tests', 1, 0, 0, 0, $now, $now)");
echo "Error handling test page (uid=2) inserted\n";

// TypoScript constants and config are split into a variant-specific
// header (the @imports / styles.content.get definition) and a shared
// body (page = PAGE, popup config, allowTags additions). The core-only
// variant skips fluid_styled_content composer-side, so importing
// EXT:fluid_styled_content TS would fail at TS-parse time — its header
// instead inlines a minimal styles.content.get definition that mirrors
// what fluid_styled_content normally provides.
// The TypoScript is not known here. The extension writes it — variant-aware —
// into the mounted scripts directory via e2e_provision_typoscript() in its
// runTests.conf; this file only puts it into sys_template. An extension that
// needs no TypoScript writes nothing and gets an empty template.
$tsConstants     = @file_get_contents('/e2e-scripts/ts-constants.typoscript');
$tsConfigHeader  = @file_get_contents('/e2e-scripts/ts-setup.typoscript');
$tsConstants     = $tsConstants === false ? '' : $tsConstants;
$tsConfigHeader  = $tsConfigHeader === false ? '' : $tsConfigHeader;
$tsConfigBody    = '';

$tsConfig = $tsConfigHeader . $tsConfigBody;

// Insert or update sys_template with BOTH constants and config
// Use ON DUPLICATE KEY UPDATE to ensure our TypoScript is applied even if TYPO3 setup pre-created it
$stmt = $pdo->prepare("INSERT INTO sys_template (uid, pid, root, title, clear, constants, config, hidden, deleted, tstamp, crdate) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE constants = VALUES(constants), config = VALUES(config), root = 1, clear = 1");
$stmt->execute([1, 1, 1, 'Root', 1, $tsConstants, $tsConfig, 0, 0, $now, $now]);
echo "sys_template record ensured with constants and config\n";
DBSETUP_EOF

    # Site configuration. The dependencies are the extension's business: a
    # site set only resolves when the extension providing it is installed, so
    # the list has to follow the same variant logic as the packages.
    E2E_SITE_DEPENDENCIES=""
    if declare -F e2e_provision_site_dependencies >/dev/null 2>&1; then
        E2E_SITE_DEPENDENCIES="$(e2e_provision_site_dependencies)"
    fi
    cat > "${E2E_SCRIPTS}/site-config.yaml" << SITECONFIG_EOF
rootPageId: 1
base: /
languages:
  - title: English
    enabled: true
    languageId: 0
    base: /
    locale: en_US.UTF-8
    navigationTitle: English
    flag: us
dependencies:
${E2E_SITE_DEPENDENCIES}
SITECONFIG_EOF

    # TypoScript, if the extension has any.
    if declare -F e2e_provision_typoscript >/dev/null 2>&1; then
        e2e_provision_typoscript
    fi

    # MariaDB, not SQLite: TYPO3's database:updateschema does not work against
    # SQLite. The network alias gives the PHP helpers a fixed hostname.
    echo "Starting MariaDB..."
    ${CONTAINER_BIN} run -d --rm ${CI_PARAMS} \
        --name mariadb-e2e-${SUFFIX} \
        --network ${NETWORK} \
        --network-alias mariadb-e2e \
        -e MYSQL_ROOT_PASSWORD=root \
        -e MYSQL_DATABASE=e2e_test \
        "${E2E_MARIADB_IMAGE:-docker.io/mariadb:10.11}" \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci >/dev/null || {
            echo "e2e: MariaDB container did not start." >&2
            return 1
        }

    # wait_for aborts the whole run via SIGINT when the port never opens, and
    # its trap runs clean_up — there is no path past it to handle here. 30s
    # rather than the default 10: MariaDB initialises its data directory first.
    wait_for mariadb-e2e 3306 30

    # TYPO3 major -> composer constraint. e2e needs v13 or newer; anything
    # older is raised rather than silently tested against a version the suite
    # was never written for.
    # -t is optional, so TYPO3_VERSION may be empty; the hooks branch on this
    # value and must never see a blank. 11 and 12 are raised because the e2e
    # suites were written against v13 and newer.
    E2E_TYPO3_VERSION="${TYPO3_VERSION:-13}"
    if [[ "${E2E_TYPO3_VERSION}" == "11" || "${E2E_TYPO3_VERSION}" == "12" ]]; then
        echo "e2e: TYPO3 ${E2E_TYPO3_VERSION} is not supported here, using 13."
        E2E_TYPO3_VERSION="13"
    fi
    case ${E2E_TYPO3_VERSION} in
        14) E2E_TYPO3_CONSTRAINT="^14.0" ;;
        *)  E2E_TYPO3_CONSTRAINT="^13.4" ;;
    esac
    export E2E_TYPO3_CONSTRAINT E2E_TYPO3_VERSION

    E2E_ADMIN_PASSWORD="${TYPO3_BACKEND_PASSWORD:-Joh316!!}"
    E2E_EXTRA_PACKAGES=""
    if declare -F e2e_provision_packages >/dev/null 2>&1; then
        E2E_EXTRA_PACKAGES="$(e2e_provision_packages)"
    fi

    # The extension under test comes from a path repository, so the instance
    # tests the working tree rather than a release.
    E2E_EXTENSION_PACKAGE="${E2E_EXTENSION_PACKAGE:-$(e2e_package_name)}"
    if [[ -z "${E2E_EXTENSION_PACKAGE}" ]]; then
        echo "e2e: cannot tell which package to install — no name in composer.json" >&2
        echo "     and no E2E_EXTENSION_PACKAGE in runTests.conf." >&2
        return 1
    fi

    echo "Installing TYPO3 ${E2E_TYPO3_CONSTRAINT} with ${E2E_EXTENSION_PACKAGE}..."
    E2E_COMPOSER_CACHE="${ROOT_DIR}/.Build/.cache/composer"
    mkdir -p "${E2E_COMPOSER_CACHE}"

    ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name e2e-setup-${SUFFIX} \
        -v ${E2E_ROOT}:/var/www/html \
        -v ${E2E_SCRIPTS}:/e2e-scripts:ro \
        -v ${ROOT_DIR}:/extension:ro \
        -v ${E2E_COMPOSER_CACHE}:/.cache/composer \
        -w /var/www/html \
        -e COMPOSER_CACHE_DIR=/.cache/composer \
        -e COMPOSER_HOME=/.cache/composer/home \
        -e COMPOSER_RETRY="${COMPOSER_RETRY:-}" \
        -e E2E_VARIANT="${E2E_VARIANT}" \
        ${IMAGE_PHP} /bin/bash -c "
            set -e

            # composer_retry is defined once, by the reusable e2e workflow, and
            # passed in. It retries transport failures three times: Composer has
            # no git fallback for a failed dist download (sourceFallback defaults
            # to false and setSourceFallback() is deprecated for removal in 2.11),
            # so a single HTTP 504 from api.github.com would otherwise end the
            # run. Empty outside CI, where this degrades to a passthrough.
            if [ -n \"\${COMPOSER_RETRY:-}\" ]; then
                eval \"\$COMPOSER_RETRY\"
            else
                composer_retry() { composer \"\$@\"; }
            fi

            composer config --global audit.block-insecure false

            composer_retry create-project typo3/cms-base-distribution:${E2E_TYPO3_CONSTRAINT} . \
                --no-interaction --no-progress --no-scripts
            composer config repositories.local path /extension
            composer_retry require ${E2E_EXTENSION_PACKAGE}:@dev --no-interaction --no-progress --no-scripts
            if [ -n '${E2E_EXTRA_PACKAGES}' ]; then
                composer_retry require ${E2E_EXTRA_PACKAGES} --no-interaction --no-progress --no-scripts
            fi
            # database:updateschema lives in typo3-console, not in the Core.
            composer_retry require helhum/typo3-console --no-interaction --no-progress --no-scripts
            composer_retry install --no-interaction --no-progress

            TYPO3_SETUP_ADMIN_USERNAME=admin \
            TYPO3_SETUP_ADMIN_PASSWORD='${E2E_ADMIN_PASSWORD}' \
            TYPO3_SETUP_ADMIN_EMAIL='admin@example.com' \
            vendor/bin/typo3 setup \
                --driver=mysqli --host=mariadb-e2e --port=3306 --dbname=e2e_test \
                --username=root --password=root --server-type=other \
                --no-interaction --force

            mkdir -p config/system config/sites/main
            cp /e2e-scripts/additional.php config/system/additional.php

            # trustedHostsPattern has to be in settings.php: TYPO3 checks it
            # before additional.php or the environment are read.
            sed -i \"s/'SYS' => \\[/'SYS' => [\\n        'trustedHostsPattern' => '.*',/\" config/system/settings.php

            vendor/bin/typo3 extension:setup
            vendor/bin/typo3 database:updateschema '*' --verbose
            cp /e2e-scripts/site-config.yaml config/sites/main/config.yaml
            php /e2e-scripts/db-setup.php

            if [ ! -f public/.htaccess ]; then
                cat > public/.htaccess << 'HTACCESS'
RewriteEngine On
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteCond %{REQUEST_FILENAME} !-l
RewriteRule ^(.*)\$ index.php [QSA,L]
HTACCESS
            fi

            chmod -R 777 var/ public/typo3temp/ public/fileadmin/
        "
    local setup_exit=$?
    if [[ ${setup_exit} -ne 0 ]]; then
        echo "" >&2
        echo "e2e: TYPO3 setup failed (exit ${setup_exit}). The instance was not" >&2
        echo "     installed — the cause is in the container output above, not in" >&2
        echo "     any later networking or test-runner error." >&2
        return ${setup_exit}
    fi

    # Demo content, after the schema exists.
    if declare -F e2e_provision_seed >/dev/null 2>&1; then
        echo "Seeding test content..."
        if ! e2e_provision_seed; then
            echo "e2e: seeding test content failed." >&2
            return 1
        fi
    fi

    # Caches in a separate container: a DI container rebuilt in the same
    # container as the install has picked up stale state before.
    echo "Warming caches..."
    ${CONTAINER_BIN} run ${CONTAINER_COMMON_PARAMS} --name e2e-cache-${SUFFIX} \
        -v ${E2E_ROOT}:/var/www/html \
        -v ${ROOT_DIR}:/extension:ro \
        -w /var/www/html \
        ${IMAGE_PHP} /bin/bash -c "
            set -e
            vendor/bin/typo3 cache:flush
            vendor/bin/typo3 cache:warmup
        "
    local cache_exit=$?
    if [[ ${cache_exit} -ne 0 ]]; then
        echo "e2e: cache warmup failed (exit ${cache_exit}); the DI container is" >&2
        echo "     not built, so the frontend would fail in a way that looks" >&2
        echo "     like a test failure." >&2
        return ${cache_exit}
    fi

    # Apache in front of PHP-FPM rather than PHP's built-in server: the
    # built-in server has no rewriting, so TYPO3's routes do not resolve.
    echo "Starting PHP-FPM..."
    ${CONTAINER_BIN} run -d --rm ${CI_PARAMS} \
        --name phpfpm-e2e-${SUFFIX} \
        --network ${NETWORK} \
        --network-alias phpfpm \
        -v ${E2E_ROOT}:/var/www/html \
        -v ${ROOT_DIR}:/extension:ro \
        -w /var/www/html \
        -e PHPFPM_USER=0 \
        -e PHPFPM_GROUP=0 \
        ${IMAGE_PHP} php-fpm -R -F >/dev/null || {
            echo "e2e: PHP-FPM container did not start." >&2
            return 1
        }
    wait_for phpfpm-e2e-${SUFFIX} 9000 20

    echo "Starting Apache..."
    ${CONTAINER_BIN} run -d --rm ${CI_PARAMS} \
        --name apache-e2e-${SUFFIX} \
        --network ${NETWORK} \
        -v ${E2E_ROOT}:/var/www/html \
        -v ${ROOT_DIR}:/extension:ro \
        -e APACHE_RUN_USER="#$(id -u)" \
        -e APACHE_RUN_GROUP="#$(id -g)" \
        -e APACHE_RUN_SERVERNAME=apache-e2e-${SUFFIX} \
        -e APACHE_RUN_DOCROOT=/var/www/html/public \
        -e PHPFPM_HOST=phpfpm \
        -e PHPFPM_PORT=9000 \
        ${IMAGE_APACHE} >/dev/null || {
            echo "e2e: Apache container did not start." >&2
            return 1
        }
    wait_for apache-e2e-${SUFFIX} 80 20

    # Assert the status, do not just print it. A 403 or a 500 here means the
    # instance is broken, and letting the suite run against it turns one setup
    # fault into a page of failing assertions that name the wrong thing.
    local code
    code=$(${CONTAINER_BIN} run --rm ${CI_PARAMS} \
        --name curl-check-${SUFFIX} \
        --network ${NETWORK} \
        ${IMAGE_PHP} curl -sS -o /dev/null -w '%{http_code}' \
        "http://apache-e2e-${SUFFIX}:80/" 2>/dev/null)
    echo "Frontend: HTTP ${code:-none}"
    if [[ "${code}" != "200" ]]; then
        echo "e2e: the frontend answered ${code:-nothing}, not 200. TYPO3 is up but" >&2
        echo "     not serving — running the suite now would report test failures" >&2
        echo "     for a broken instance." >&2
        return 1
    fi

    TYPO3_BASE_URL="http://apache-e2e-${SUFFIX}"
    export TYPO3_BASE_URL
}

# Remove what e2e_provision built. Containers are handled by clean_up, which
# takes down everything on ${NETWORK}; the instance directory is not, and only
# the caller knows whether the run passed and it can go.
e2e_provision_teardown() {
    local suite_exit="${1:-1}"
    if [[ "${suite_exit}" -eq 0 ]]; then
        e2e_remove_container_owned_dir "${ROOT_DIR}/.Build/e2e-typo3"
        rm -rf "${ROOT_DIR}/.Build/e2e-scripts"
    else
        echo "e2e environment kept at ${ROOT_DIR}/.Build/e2e-typo3 for inspection"
    fi
    # Teardown must never change the run's verdict: the suite's exit code has
    # already been decided by the time this is called.
    return 0
}
