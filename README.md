# wordpress-migrate-bash

A bash script for migrating WordPress between domains or environments. Unlike a simple find/replace, this tool handles PHP serialized data properly — preserving string length counts so plugin settings, widget configurations, and theme options don't break.

## The Problem

WordPress stores many settings as [PHP serialized strings](https://www.php.net/manual/en/function.serialize.php) in the database. A serialized string looks like this:

```
s:28:"https://old-domain.com/image";
```

The `28` is the character count. If you do a plain text replacement to a new domain, the length changes but the count doesn't — and WordPress silently fails to unserialize the data, losing your settings.

This tool replaces URLs **and** recalculates serialized string lengths automatically.

## How It Works

The script auto-detects the best available method:

| Priority | Method | Serialization-Safe | Requirement |
|---|---|---|---|
| 1 | **WP-CLI** | Yes | `wp` command installed |
| 2 | **PHP** | Yes | `php` with PDO_MySQL |
| 3 | **Simple** | No (warns you) | `sed` only |

It reads database credentials directly from `wp-config.php`, creates a backup before making changes, and handles both regular and escaped URL formats (e.g. `https:\/\/domain.com` as stored in JSON columns).

## Requirements

- `bash` 4.0+
- `mysql` and `mysqldump`
- Read access to `wp-config.php`
- One of: [WP-CLI](https://wp-cli.org/) (recommended), PHP with PDO_MySQL, or sed (fallback)

## Quick Start

```bash
git clone https://github.com/alanpinnt/wordpress-migrate-bash.git
cd wordpress-migrate-bash
chmod +x wp-migrate.sh

# Migrate from staging to production
./wp-migrate.sh --from https://staging.example.com --to https://example.com --path /var/www/html
```

## Usage

```bash
# Basic migration
./wp-migrate.sh --from https://old-domain.com --to https://new-domain.com

# Preview changes without modifying anything
./wp-migrate.sh --from https://old.com --to https://new.com --dry-run

# Export modified SQL to a file instead of importing directly
./wp-migrate.sh --from https://old.com --to https://new.com --export migration.sql

# Also update wp-config.php (WP_HOME, WP_SITEURL, etc.)
./wp-migrate.sh --from https://old.com --to https://new.com --update-config

# Skip the automatic backup (if you already have one)
./wp-migrate.sh --from https://old.com --to https://new.com --skip-backup

# Specify a custom WordPress path
./wp-migrate.sh --from https://old.com --to https://new.com --path /var/www/mysite

# Verbose output for debugging
./wp-migrate.sh --from https://old.com --to https://new.com --verbose
```

### Options

| Flag | Description |
|---|---|
| `-f, --from URL` | Old URL to search for (required) |
| `-t, --to URL` | New URL to replace with (required) |
| `-p, --path DIR` | WordPress installation path (default: `/var/www/html`) |
| `-n, --dry-run` | Preview changes without modifying the database |
| `-e, --export FILE` | Write modified SQL to file instead of importing |
| `--skip-backup` | Skip the automatic pre-migration backup |
| `--update-config` | Also update URLs in `wp-config.php` |
| `-v, --verbose` | Enable detailed output |
| `-h, --help` | Show help message |

## Common Migration Scenarios

### Staging to Production

```bash
./wp-migrate.sh \
  --from https://staging.example.com \
  --to https://example.com \
  --update-config
```

### HTTP to HTTPS

```bash
./wp-migrate.sh \
  --from http://example.com \
  --to https://example.com \
  --update-config
```

### Domain Change

```bash
./wp-migrate.sh \
  --from https://old-domain.com \
  --to https://new-domain.com \
  --update-config
```

### Local Dev to Production

```bash
./wp-migrate.sh \
  --from http://localhost:8080/wordpress \
  --to https://example.com
```

## Post-Migration Checklist

After running the migration:

1. **Flush permalinks** — Go to Settings > Permalinks > Save Changes
2. **Clear caches** — Purge any caching plugin (W3 Total Cache, WP Super Cache, etc.)
3. **Verify the site** — Check pages, images, and plugin settings
4. **Update DNS** — Point the new domain to the server if needed
5. **Check SSL** — Ensure the certificate covers the new domain

## Safety Features

- **Automatic backup** — Creates a gzipped SQL dump before any changes
- **Dry run mode** — Preview all replacements without touching the database
- **Export mode** — Generate a SQL file for review before importing manually
- **Trailing slash normalization** — Prevents mismatched URL formats
- **Escaped URL handling** — Catches `https:\/\/` JSON-encoded URLs in a second pass

## License

[MIT](LICENSE)
