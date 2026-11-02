#!/usr/bin/env bash
# Update Drupal packages flagged by `composer audit`, then commit composer.lock.
# Run from a Drupal project root (the directory with composer.json / composer.lock).

set -u

confirm()
{
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Prints "name version" lines for every package in composer.lock.
lock_versions()
{
    jq -r '[.packages[], .["packages-dev"][]?] | .[] | "\(.name) \(.version)"' composer.lock | sort
}

main()
{
    local cmd
    for cmd in composer jq git; do
        command -v "$cmd" > /dev/null || { echo "Missing required command: $cmd" >&2; return 1; }
    done

    if [[ ! -f composer.json || ! -f composer.lock ]]; then
        echo "No composer.json/composer.lock in $(pwd)" >&2
        return 1
    fi

    # Step 1: composer audit (exits non-zero when advisories exist, so ignore the status)
    echo "Running composer audit..."
    local audit_json
    audit_json=$(composer audit --format=json --no-interaction --locked 2> /dev/null)
    if ! jq -e . <<< "$audit_json" > /dev/null 2>&1; then
        echo "Could not parse composer audit output:" >&2
        echo "$audit_json" >&2
        return 1
    fi

    # Step 2: extract package names; drupal/core and drupal/core-* collapse to drupal/core-*
    local names
    names=$(jq -r '
        (.advisories // {}) | if type == "object" then keys[] else empty end
    ' <<< "$audit_json")

    local packages=() skipped=() name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if [[ "$name" =~ ^drupal/core(-.*)?$ ]]; then
            name='drupal/core-*'
        elif [[ "$name" != drupal/* ]]; then
            skipped+=("$name")
            continue
        fi
        # dedupe
        if [[ ${#packages[@]} -eq 0 ]] || [[ ! " ${packages[*]} " == *" $name "* ]]; then
            packages+=("$name")
        fi
    done <<< "$names"

    if [[ ${#skipped[@]} -gt 0 ]]; then
        echo "Skipping non-Drupal packages with advisories: ${skipped[*]}"
    fi

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No Drupal packages with security advisories. Nothing to update."
        return 0
    fi

    # Step 3: build, preview, and run composer update
    local update_cmd=(composer update -W "${packages[@]}")
    echo
    echo "Update command:"
    printf '  %q' "${update_cmd[@]}"
    echo $'\n'

    confirm "Run this command?" || { echo "Aborted."; return 0; }

    local before after
    before=$(lock_versions)
    "${update_cmd[@]}" || { echo "composer update failed." >&2; return 1; }
    after=$(lock_versions)

    # Step 4: build, preview, and run the commit
    local changes
    changes=$(join -j1 <(echo "$before") <(echo "$after") \
        | awk '$2 != $3 && $1 ~ /^drupal\// { printf "* %s %s -> %s\n", $1, $2, $3 }')

    if [[ -z "$changes" ]]; then
        echo "composer.lock has no Drupal package changes. Nothing to commit."
        return 0
    fi

    local message
    message=$(printf 'Drupal updates\n\n%s' "$changes")

    echo
    echo "Commit command:"
    echo "  git commit composer.lock -m <message>"
    echo "Message:"
    sed 's/^/  | /' <<< "$message"
    echo

    confirm "Commit composer.lock?" || { echo "Not committed."; return 0; }

    git commit -m "$message" -- composer.lock
}

main "$@"
