#!/usr/bin/env bash
#
# wp-migrate.sh - WordPress domain/environment migration tool
# Performs serialization-aware search-and-replace on the WordPress database.
# Simple find/replace breaks PHP serialized data — this tool handles it properly.
#
# Usage: ./wp-migrate.sh [options]
#   -f, --from URL       Old URL (e.g. https://old-domain.com)
#   -t, --to URL         New URL (e.g. https://new-domain.com)
#   -p, --path DIR       WordPress installation path (default: /var/www/html)
#   -n, --dry-run        Show what would change without modifying the database
#   -e, --export FILE    Export modified SQL to file instead of importing directly
#   --skip-backup        Skip the pre-migration database backup
#   --update-config      Also update wp-config.php with new URLs
#   -v, --verbose        Enable verbose output
#   -h, --help           Show this help message

set -euo pipefail

# ---------- Defaults ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FROM_URL=""
TO_URL=""
WP_PATH="/var/www/html"
DRY_RUN=false
EXPORT_FILE=""
SKIP_BACKUP=false
UPDATE_CONFIG=false
VERBOSE=false
METHOD=""  # auto-detected: wpcli, php, or simple

DB_HOST=""
DB_NAME=""
DB_USER=""
DB_PASS=""

# ---------- Functions ----------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

verbose() {
    [[ "$VERBOSE" == true ]] && log "[VERBOSE] $*"
}

error() {
    log "[ERROR] $*" >&2
}

die() {
    error "$*"
    exit 1
}

usage() {
    sed -n '6,15p' "$0" | sed 's/^# \?//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--from) FROM_URL="$2"; shift 2 ;;
            -t|--to) TO_URL="$2"; shift 2 ;;
            -p|--path) WP_PATH="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -e|--export) EXPORT_FILE="$2"; shift 2 ;;
            --skip-backup) SKIP_BACKUP=true; shift ;;
            --update-config) UPDATE_CONFIG=true; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -h|--help) usage ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$FROM_URL" ]] && die "Missing required option: --from"
    [[ -z "$TO_URL" ]] && die "Missing required option: --to"

    # Strip trailing slashes for consistency
    FROM_URL="${FROM_URL%/}"
    TO_URL="${TO_URL%/}"

    [[ "$FROM_URL" == "$TO_URL" ]] && die "--from and --to cannot be the same"
}

validate() {
    [[ -d "$WP_PATH" ]] || die "WordPress path not found: $WP_PATH"
    [[ -f "${WP_PATH}/wp-config.php" ]] || die "wp-config.php not found in $WP_PATH"

    for cmd in mysqldump mysql; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
}

detect_db_credentials() {
    local wp_config="${WP_PATH}/wp-config.php"

    DB_NAME="$(grep -oP "define\(\s*'DB_NAME'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)"
    DB_USER="$(grep -oP "define\(\s*'DB_USER'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)"
    DB_PASS="$(grep -oP "define\(\s*'DB_PASSWORD'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)"
    DB_HOST="$(grep -oP "define\(\s*'DB_HOST'\s*,\s*'\\K[^']+" "$wp_config" 2>/dev/null || true)"
    DB_HOST="${DB_HOST:-localhost}"

    [[ -z "$DB_NAME" ]] && die "Could not read DB_NAME from wp-config.php"
    [[ -z "$DB_USER" ]] && die "Could not read DB_USER from wp-config.php"

    verbose "Database: $DB_NAME on $DB_HOST as $DB_USER"
}

detect_method() {
    if command -v wp &>/dev/null; then
        METHOD="wpcli"
        log "Using WP-CLI for serialization-safe replacement"
    elif command -v php &>/dev/null; then
        METHOD="php"
        log "Using PHP for serialization-safe replacement"
    else
        METHOD="simple"
        log "WARNING: Neither WP-CLI nor PHP found — using simple text replacement"
        log "WARNING: This may break serialized data in the database"
    fi
}

mysql_args() {
    local args=(-h "$DB_HOST" -u "$DB_USER")
    if [[ -n "$DB_PASS" ]]; then
        args+=(-p"$DB_PASS")
    fi
    echo "${args[@]}"
}

create_backup() {
    if [[ "$SKIP_BACKUP" == true ]]; then
        log "Skipping pre-migration backup (--skip-backup)"
        return
    fi

    local backup_file="${WP_PATH}/pre-migration-$(date +%Y%m%d_%H%M%S).sql.gz"
    log "Creating pre-migration backup: $backup_file"

    local args
    read -ra args <<< "$(mysql_args)"

    mysqldump "${args[@]}" \
        --single-transaction \
        --routines \
        --triggers \
        "$DB_NAME" | gzip > "$backup_file"

    local size
    size="$(du -h "$backup_file" | cut -f1)"
    log "Backup complete ($size). Restore with:"
    log "  gunzip < $backup_file | mysql $(mysql_args) $DB_NAME"
}

# --- WP-CLI method ---

migrate_wpcli() {
    local wp_args=(--path="$WP_PATH" --all-tables --precise --recurse-objects)

    if [[ "$DRY_RUN" == true ]]; then
        wp_args+=(--dry-run)
    fi

    if [[ -n "$EXPORT_FILE" ]]; then
        wp_args+=(--export="$EXPORT_FILE")
    fi

    log "Running: wp search-replace '$FROM_URL' '$TO_URL'"
    wp search-replace "$FROM_URL" "$TO_URL" "${wp_args[@]}"

    # Also handle non-www/www variants and protocol differences
    local from_domain to_domain
    from_domain="$(echo "$FROM_URL" | sed -E 's|^https?://||')"
    to_domain="$(echo "$TO_URL" | sed -E 's|^https?://||')"

    if [[ "$from_domain" != "$to_domain" ]]; then
        # Handle escaped URLs (WordPress stores these in some places)
        local from_escaped to_escaped
        from_escaped="$(echo "$FROM_URL" | sed 's|/|\\/|g')"
        to_escaped="$(echo "$TO_URL" | sed 's|/|\\/|g')"

        if [[ "$from_escaped" != "$FROM_URL" ]]; then
            log "Running: wp search-replace '$from_escaped' '$to_escaped' (escaped URLs)"
            wp search-replace "$from_escaped" "$to_escaped" "${wp_args[@]}"
        fi
    fi
}

# --- PHP method ---

generate_php_script() {
    local tmp_php
    tmp_php="$(mktemp /tmp/wp-migrate-XXXXXX.php)"

    cat > "$tmp_php" << 'PHPSCRIPT'
<?php
/**
 * Serialization-aware search and replace for WordPress databases.
 * Handles nested serialized strings by recursively unserializing,
 * replacing, and re-serializing with corrected string lengths.
 *
 * Usage: php this_script.php <from> <to> <host> <name> <user> <pass> [--dry-run] [--export=file]
 */

if ($argc < 7) {
    fwrite(STDERR, "Usage: php $argv[0] <from> <to> <host> <dbname> <dbuser> <dbpass> [--dry-run] [--export=file]\n");
    exit(1);
}

$from     = $argv[1];
$to       = $argv[2];
$host     = $argv[3];
$dbname   = $argv[4];
$user     = $argv[5];
$pass     = $argv[6];
$dry_run  = false;
$export   = null;

for ($i = 7; $i < $argc; $i++) {
    if ($argv[$i] === '--dry-run') $dry_run = true;
    if (strpos($argv[$i], '--export=') === 0) $export = substr($argv[$i], 9);
}

try {
    $dsn = "mysql:host=$host;dbname=$dbname;charset=utf8mb4";
    $pdo = new PDO($dsn, $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES utf8mb4",
    ]);
} catch (PDOException $e) {
    fwrite(STDERR, "Database connection failed: " . $e->getMessage() . "\n");
    exit(1);
}

$export_handle = null;
if ($export) {
    $export_handle = fopen($export, 'w');
    if (!$export_handle) {
        fwrite(STDERR, "Cannot open export file: $export\n");
        exit(1);
    }
}

function recursive_replace($from, $to, $data) {
    if (is_string($data)) {
        $unserialized = @unserialize($data);
        if ($unserialized !== false || $data === 'b:0;') {
            $replaced = recursive_replace($from, $to, $unserialized);
            return serialize($replaced);
        }
        return str_replace($from, $to, $data);
    }

    if (is_array($data)) {
        $result = [];
        foreach ($data as $key => $value) {
            $new_key = recursive_replace($from, $to, $key);
            $result[$new_key] = recursive_replace($from, $to, $value);
        }
        return $result;
    }

    if (is_object($data)) {
        $props = get_object_vars($data);
        foreach ($props as $key => $value) {
            $data->$key = recursive_replace($from, $to, $value);
        }
        return $data;
    }

    return $data;
}

// Get all tables
$tables = $pdo->query("SHOW TABLES")->fetchAll(PDO::FETCH_COLUMN);
$total_changes = 0;

foreach ($tables as $table) {
    // Get columns
    $cols = $pdo->query("SHOW COLUMNS FROM `$table`")->fetchAll(PDO::FETCH_ASSOC);
    $text_cols = [];
    $primary_key = null;

    foreach ($cols as $col) {
        $type = strtolower($col['Type']);
        if (preg_match('/(char|text|blob|enum|set)/', $type)) {
            $text_cols[] = $col['Field'];
        }
        if ($col['Key'] === 'PRI') {
            $primary_key = $col['Field'];
        }
    }

    if (empty($text_cols)) continue;

    // Build WHERE clause to only fetch rows containing the search string
    $where_parts = [];
    foreach ($text_cols as $col) {
        $where_parts[] = "`$col` LIKE " . $pdo->quote("%$from%");
    }
    $where = implode(' OR ', $where_parts);

    $rows = $pdo->query("SELECT * FROM `$table` WHERE $where")->fetchAll(PDO::FETCH_ASSOC);
    $table_changes = 0;

    foreach ($rows as $row) {
        $updates = [];

        foreach ($text_cols as $col) {
            if (!isset($row[$col]) || $row[$col] === null) continue;
            if (strpos($row[$col], $from) === false) continue;

            $new_val = recursive_replace($from, $to, $row[$col]);

            if ($new_val !== $row[$col]) {
                $updates[$col] = $new_val;
            }
        }

        if (!empty($updates)) {
            $table_changes += count($updates);

            if (!$dry_run && !$export_handle) {
                $set_parts = [];
                $params = [];
                foreach ($updates as $col => $val) {
                    $set_parts[] = "`$col` = ?";
                    $params[] = $val;
                }

                if ($primary_key && isset($row[$primary_key])) {
                    $sql = "UPDATE `$table` SET " . implode(', ', $set_parts) . " WHERE `$primary_key` = ?";
                    $params[] = $row[$primary_key];
                    $stmt = $pdo->prepare($sql);
                    $stmt->execute($params);
                }
            }

            if ($export_handle) {
                foreach ($updates as $col => $val) {
                    $escaped = $pdo->quote($val);
                    if ($primary_key && isset($row[$primary_key])) {
                        $pk_escaped = $pdo->quote($row[$primary_key]);
                        fwrite($export_handle, "UPDATE `$table` SET `$col` = $escaped WHERE `$primary_key` = $pk_escaped;\n");
                    }
                }
            }
        }
    }

    if ($table_changes > 0) {
        echo "  $table: $table_changes replacement(s)\n";
        $total_changes += $table_changes;
    }
}

if ($export_handle) fclose($export_handle);

$mode = $dry_run ? ' (dry run)' : ($export ? " (exported to $export)" : '');
echo "\nTotal: $total_changes replacement(s)$mode\n";
PHPSCRIPT

    echo "$tmp_php"
}

migrate_php() {
    local php_script
    php_script="$(generate_php_script)"

    local php_args=("$FROM_URL" "$TO_URL" "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASS")

    if [[ "$DRY_RUN" == true ]]; then
        php_args+=("--dry-run")
    fi

    if [[ -n "$EXPORT_FILE" ]]; then
        php_args+=("--export=$EXPORT_FILE")
    fi

    log "Running PHP serialization-aware replacement"
    php "$php_script" "${php_args[@]}"

    # Handle escaped URLs as a second pass
    local from_escaped to_escaped
    from_escaped="$(echo "$FROM_URL" | sed 's|/|\\/|g')"
    to_escaped="$(echo "$TO_URL" | sed 's|/|\\/|g')"

    if [[ "$from_escaped" != "$FROM_URL" ]]; then
        log "Running second pass for escaped URLs"
        php_args=("$from_escaped" "$to_escaped" "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASS")
        [[ "$DRY_RUN" == true ]] && php_args+=("--dry-run")
        [[ -n "$EXPORT_FILE" ]] && php_args+=("--export=$EXPORT_FILE")
        php "$php_script" "${php_args[@]}"
    fi

    rm -f "$php_script"
}

# --- Simple method (fallback, no serialization support) ---

migrate_simple() {
    log "WARNING: Simple replacement does not handle serialized data"
    log "WARNING: This may break plugin/theme settings stored in the database"

    local dump_file
    dump_file="$(mktemp /tmp/wp-migrate-dump-XXXXXX.sql)"

    local args
    read -ra args <<< "$(mysql_args)"

    log "Dumping database..."
    mysqldump "${args[@]}" --single-transaction "$DB_NAME" > "$dump_file"

    local count
    count="$(grep -c "$FROM_URL" "$dump_file" || true)"
    log "Found $count occurrence(s) of '$FROM_URL'"

    if [[ "$count" -eq 0 ]]; then
        log "Nothing to replace"
        rm -f "$dump_file"
        return
    fi

    # Also replace escaped versions
    local from_escaped to_escaped
    from_escaped="$(echo "$FROM_URL" | sed 's|/|\\/|g')"
    to_escaped="$(echo "$TO_URL" | sed 's|/|\\/|g')"

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY RUN] Would replace $count occurrences"
        rm -f "$dump_file"
        return
    fi

    log "Replacing URLs in dump..."
    sed -i "s|${FROM_URL}|${TO_URL}|g" "$dump_file"

    if [[ "$from_escaped" != "$FROM_URL" ]]; then
        sed -i "s|${from_escaped}|${to_escaped}|g" "$dump_file"
    fi

    if [[ -n "$EXPORT_FILE" ]]; then
        mv "$dump_file" "$EXPORT_FILE"
        log "Modified SQL exported to: $EXPORT_FILE"
    else
        log "Importing modified database..."
        mysql "${args[@]}" "$DB_NAME" < "$dump_file"
        rm -f "$dump_file"
        log "Database import complete"
    fi
}

# --- wp-config.php update ---

update_wp_config() {
    if [[ "$UPDATE_CONFIG" != true ]]; then
        return
    fi

    local wp_config="${WP_PATH}/wp-config.php"
    log "Updating wp-config.php"

    if [[ "$DRY_RUN" == true ]]; then
        local matches
        matches="$(grep -c "$FROM_URL" "$wp_config" 2>/dev/null || true)"
        log "[DRY RUN] Would replace $matches occurrence(s) in wp-config.php"
        return
    fi

    if grep -q "$FROM_URL" "$wp_config" 2>/dev/null; then
        sed -i "s|${FROM_URL}|${TO_URL}|g" "$wp_config"
        log "wp-config.php updated"
    else
        verbose "No occurrences of '$FROM_URL' found in wp-config.php"
    fi
}

# --- Summary ---

print_summary() {
    log "────────────────────────────────"
    log "Migration summary:"
    log "  From:   $FROM_URL"
    log "  To:     $TO_URL"
    log "  Method: $METHOD"
    [[ "$DRY_RUN" == true ]] && log "  Mode:   DRY RUN (no changes made)"
    [[ -n "$EXPORT_FILE" ]] && log "  Export: $EXPORT_FILE"
    log "────────────────────────────────"
}

# ---------- Main ----------

main() {
    parse_args "$@"
    validate
    detect_db_credentials
    detect_method

    log "Starting WordPress migration"
    log "  From: $FROM_URL"
    log "  To:   $TO_URL"

    create_backup

    case "$METHOD" in
        wpcli)  migrate_wpcli ;;
        php)    migrate_php ;;
        simple) migrate_simple ;;
    esac

    update_wp_config
    print_summary

    log "Migration complete!"
    if [[ "$DRY_RUN" == false && -z "$EXPORT_FILE" ]]; then
        log "Remember to:"
        log "  1. Flush permalinks (Settings > Permalinks > Save)"
        log "  2. Clear any caching plugins"
        log "  3. Verify the site loads correctly on the new URL"
    fi
}

main "$@"
