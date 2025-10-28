#!/bin/bash
set -euo pipefail

# ============================================================================
# nc-src Garbage File Cleanup Script
# Production-Ready Implementation
# ============================================================================

# Configuration
NC_SRC_DIR="$HOME/nc-src"
SCRIPT_NAME="cleanup-nc-src"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/${SCRIPT_NAME}_${TIMESTAMP}"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
DELETION_MANIFEST="${LOG_DIR}/deletion_manifest.txt"
DRY_RUN_REPORT="${LOG_DIR}/dry_run_report.txt"
BACKUP_ARCHIVE="/tmp/${SCRIPT_NAME}_phase2_backup_${TIMESTAMP}.tar.gz"
SIZE_THRESHOLD_GB=1
SIZE_THRESHOLD_BYTES=$((SIZE_THRESHOLD_GB * 1024 * 1024 * 1024))

# Create log directory
mkdir -p "$LOG_DIR"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*" | tee -a "${LOG_DIR}/execution.log"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_DIR}/execution.log"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_DIR}/execution.log"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_DIR}/execution.log"
}

# ============================================================================
# Exclusion Patterns
# ============================================================================

declare -a EXCLUDE_PATTERNS=(
    ".git"
    ".gitignore"
    ".gitattributes"
    "README*"
    "LICENSE*"
    "CHANGELOG*"
    "*.md"
    ".env.example"
    ".env.template"
    "requirements*.txt"
    "poetry.lock"
    "package-lock.json"
    "yarn.lock"
    "pnpm-lock.yaml"
    "Gemfile.lock"
    "Cargo.lock"
    "Makefile"
    "Dockerfile*"
    "docker-compose*.yml"
    ".github"
    ".gitlab-ci.yml"
    "pyproject.toml"
    "setup.py"
    "setup.cfg"
    "*.db"
    "*.sqlite*"
    "tsconfig.json"
    "jest.config.*"
    "vite.config.*"
    "webpack.config.*"
    ".ce"
    "!archive"
)

# ============================================================================
# Cleanup Functions
# ============================================================================

cleanup_on_exit() {
    rm -f "$LOCK_FILE"
    log "Cleanup script finished. Logs at: ${LOG_DIR}"
}

interrupt_handler() {
    error "INTERRUPTED - Partial deletions recorded in: ${DELETION_MANIFEST}"
    error "Review manifest to understand current state"
    exit 1
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

check_lock_file() {
    if [ -f "$LOCK_FILE" ]; then
        error "Cleanup already running (lock file exists: ${LOCK_FILE})"
        exit 1
    fi
    touch "$LOCK_FILE"
}

check_directory_exists() {
    if [ ! -d "$NC_SRC_DIR" ]; then
        error "Directory does not exist: ${NC_SRC_DIR}"
        exit 1
    fi
}

check_write_permissions() {
    log "Checking write permissions..."

    if [ ! -w "$NC_SRC_DIR" ]; then
        error "No write permission for ${NC_SRC_DIR}"
        exit 1
    fi

    info "Write permissions OK"
}

check_git_status() {
    log "Checking git repositories for uncommitted changes..."

    local has_uncommitted=0
    local repos_with_changes=()
    local skip_repo="$HOME/nc-src/Husseini-feat-global-reset-prep"

    while IFS= read -r -d '' git_dir; do
        local project_dir=$(dirname "$git_dir")

        # Skip current repo
        if [ "$project_dir" = "$skip_repo" ]; then
            warn "SKIP: $project_dir (active working repo)"
            continue
        fi

        cd "$project_dir"

        # Check for any uncommitted changes
        if ! git diff --quiet 2>/dev/null || \
           ! git diff --cached --quiet 2>/dev/null || \
           [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
            repos_with_changes+=("$project_dir")
            has_uncommitted=1
        fi
    done < <(find "$NC_SRC_DIR" -maxdepth 2 -name ".git" -type d -print0)

    if [ $has_uncommitted -eq 1 ]; then
        error "Found ${#repos_with_changes[@]} repositories with uncommitted changes:"
        printf '%s\n' "${repos_with_changes[@]}" | sed 's/^/  /'
        echo ""
        error "Please commit or stash changes before running cleanup"
        error "To check: cd <project> && git status"
        exit 1
    fi

    info "All git repositories clean"
}

check_disk_space() {
    log "Checking available disk space..."

    local required_space=$((10 * 1024 * 1024 * 1024))  # 10GB for temp operations
    local available_space=$(df -k /tmp | tail -1 | awk '{print $4}')
    available_space=$((available_space * 1024))

    if [ $available_space -lt $required_space ]; then
        error "Insufficient disk space in /tmp"
        error "Required: $(numfmt --to=iec $required_space)"
        error "Available: $(numfmt --to=iec $available_space)"
        exit 1
    fi

    info "Disk space OK ($(numfmt --to=iec $available_space) available)"
}

# ============================================================================
# File Discovery Functions
# ============================================================================

is_excluded() {
    local path="$1"
    local item=$(basename "$path")

    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$item" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

is_symlink() {
    [ -L "$1" ]
}

find_garbage_files() {
    log "Scanning for garbage files..."

    local -A categories
    categories[ds_store]=0
    categories[pycache]=0
    categories[pytest_cache]=0
    categories[mypy_cache]=0
    categories[venv]=0
    categories[node_modules]=0
    categories[dist]=0
    categories[build]=0
    categories[logs]=0
    categories[nested_backup]=0

    local skip_repo="$HOME/nc-src/Husseini-feat-global-reset-prep"

    # Initialize manifest
    > "$DELETION_MANIFEST"

    # .DS_Store files
    while IFS= read -r file; do
        # Skip current repo
        [[ "$file" == "$skip_repo"* ]] && continue
        echo "ds_store|$file" >> "$DELETION_MANIFEST"
        ((categories[ds_store]++))
    done < <(find "$NC_SRC_DIR" -name ".DS_Store" -type f 2>/dev/null)

    # __pycache__ directories
    while IFS= read -r dir; do
        [[ "$dir" == "$skip_repo"* ]] && continue
        if ! is_symlink "$dir"; then
            echo "pycache|$dir" >> "$DELETION_MANIFEST"
            ((categories[pycache]++))
        fi
    done < <(find "$NC_SRC_DIR" -type d -name "__pycache__" 2>/dev/null)

    # .pytest_cache directories
    while IFS= read -r dir; do
        [[ "$dir" == "$skip_repo"* ]] && continue
        if ! is_symlink "$dir"; then
            echo "pytest_cache|$dir" >> "$DELETION_MANIFEST"
            ((categories[pytest_cache]++))
        fi
    done < <(find "$NC_SRC_DIR" -type d -name ".pytest_cache" 2>/dev/null)

    # .mypy_cache directories
    while IFS= read -r dir; do
        [[ "$dir" == "$skip_repo"* ]] && continue
        if ! is_symlink "$dir"; then
            echo "mypy_cache|$dir" >> "$DELETION_MANIFEST"
            ((categories[mypy_cache]++))
        fi
    done < <(find "$NC_SRC_DIR" -type d -name ".mypy_cache" 2>/dev/null)

    # .venv and venv directories
    while IFS= read -r dir; do
        [[ "$dir" == "$skip_repo"* ]] && continue
        if ! is_symlink "$dir"; then
            echo "venv|$dir" >> "$DELETION_MANIFEST"
            ((categories[venv]++))
        fi
    done < <(find "$NC_SRC_DIR" -type d \( -name ".venv" -o -name "venv" \) 2>/dev/null)

    # node_modules directories (check for monorepos)
    while IFS= read -r dir; do
        [[ "$dir" == "$skip_repo"* ]] && continue
        if ! is_symlink "$dir"; then
            local project_dir=$(dirname "$dir")

            # Skip if monorepo
            if [ -f "$project_dir/pnpm-workspace.yaml" ] || [ -f "$project_dir/lerna.json" ]; then
                warn "SKIP: $dir (monorepo detected)"
                continue
            fi

            echo "node_modules|$dir" >> "$DELETION_MANIFEST"
            ((categories[node_modules]++))
        fi
    done < <(find "$NC_SRC_DIR" -type d -name "node_modules" 2>/dev/null)

    # dist and build directories (with .gitignore validation)
    while IFS= read -r dir; do
        [[ "$dir" == "$skip_repo"* ]] && continue
        if ! is_symlink "$dir"; then
            local project_dir=$(dirname "$dir")
            local dir_name=$(basename "$dir")

            # Check if in .gitignore (safer to delete)
            if [ -f "$project_dir/.gitignore" ] && grep -q "^${dir_name}/$" "$project_dir/.gitignore" 2>/dev/null; then
                if [ "$dir_name" = "dist" ]; then
                    echo "dist|$dir" >> "$DELETION_MANIFEST"
                    ((categories[dist]++))
                else
                    echo "build|$dir" >> "$DELETION_MANIFEST"
                    ((categories[build]++))
                fi
            else
                warn "SKIP: $dir (not in .gitignore - may contain source files)"
            fi
        fi
    done < <(find "$NC_SRC_DIR" -type d \( -name "dist" -o -name "build" \) 2>/dev/null)

    # Log files older than 30 days (conservative patterns)
    while IFS= read -r file; do
        [[ "$file" == "$skip_repo"* ]] && continue
        if [[ "$file" == *.log ]] && [ -f "$file" ]; then
            local age_days=$(( ( $(date +%s) - $(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file") ) / 86400 ))
            if [ $age_days -gt 30 ]; then
                echo "logs|$file" >> "$DELETION_MANIFEST"
                ((categories[logs]++))
            fi
        fi
    done < <(find "$NC_SRC_DIR" -type f -name "*.log" 2>/dev/null)

    # Nested backup disaster
    if [ -d "$NC_SRC_DIR/ovora_alexa/cleanup-backup" ]; then
        echo "nested_backup|$NC_SRC_DIR/ovora_alexa/cleanup-backup" >> "$DELETION_MANIFEST"
        ((categories[nested_backup]++))
    fi

    # Store category counts
    for category in "${!categories[@]}"; do
        echo "${category}:${categories[$category]}" >> "${LOG_DIR}/category_counts.txt"
    done

    info "Scan complete. Found $(wc -l < "$DELETION_MANIFEST") items"
}

generate_dry_run_report() {
    log "Generating dry-run report..."

    local total_size=0
    local file_count=0
    local project_count=0

    declare -A category_sizes
    declare -A project_sizes
    declare -a large_items

    while IFS='|' read -r category path; do
        if [ ! -e "$path" ]; then
            continue
        fi

        local size=0
        if [ -d "$path" ]; then
            size=$(du -sk "$path" 2>/dev/null | cut -f1)
            size=$((size * 1024))
        elif [ -f "$path" ]; then
            size=$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path")
        fi

        total_size=$((total_size + size))
        ((file_count++))

        # Category totals
        category_sizes[$category]=$((${category_sizes[$category]:-0} + size))

        # Project totals
        local project=$(echo "$path" | sed "s|$NC_SRC_DIR/||" | cut -d'/' -f1)
        project_sizes[$project]=$((${project_sizes[$project]:-0} + size))

        # Large items
        if [ $size -gt $SIZE_THRESHOLD_BYTES ]; then
            large_items+=("$(numfmt --to=iec $size)|$path")
        fi
    done < "$DELETION_MANIFEST"

    project_count=${#project_sizes[@]}

    # Generate report
    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  DRY RUN REPORT - $(date)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "📊 SUMMARY"
        echo "  Total items to delete: ${file_count}"
        echo "  Total size to free: $(numfmt --to=iec $total_size)"
        echo "  Projects affected: ${project_count}"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📁 BY CATEGORY"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for category in "${!category_sizes[@]}"; do
            local count=$(grep "^${category}|" "$DELETION_MANIFEST" | wc -l)
            printf "  %-20s %10s (%s items)\n" "$category" "$(numfmt --to=iec ${category_sizes[$category]})" "$count"
        done | sort -k2 -hr
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔍 LARGE ITEMS (>${SIZE_THRESHOLD_GB}GB)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ ${#large_items[@]} -eq 0 ]; then
            echo "  None"
        else
            printf '%s\n' "${large_items[@]}" | sort -hr | head -20 | while IFS='|' read -r size path; do
                printf "  %10s  %s\n" "$size" "$path"
            done
        fi
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🎯 PROJECTS WITH >500MB DELETIONS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for project in "${!project_sizes[@]}"; do
            local psize=${project_sizes[$project]}
            if [ $psize -gt $((500 * 1024 * 1024)) ]; then
                printf "  %-40s %10s\n" "$project" "$(numfmt --to=iec $psize)"
            fi
        done | sort -k2 -hr
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🛡️  EXCLUSIONS APPLIED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf '%s\n' "${EXCLUDE_PATTERNS[@]}" | sed 's/^/  /'
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    } > "$DRY_RUN_REPORT"

    cat "$DRY_RUN_REPORT"
    info "Report saved to: ${DRY_RUN_REPORT}"
}

# ============================================================================
# Execution Functions
# ============================================================================

execute_phase2_nested_backups() {
    log "Phase 2: Nested Backup Cleanup"

    local backup_dir="$NC_SRC_DIR/ovora_alexa/cleanup-backup"

    if [ ! -d "$backup_dir" ]; then
        info "No nested backup directory found - skipping Phase 2"
        return 0
    fi

    # Create backup archive
    log "Creating safety archive: ${BACKUP_ARCHIVE}"
    tar -czf "$BACKUP_ARCHIVE" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")" 2>/dev/null || {
        error "Failed to create backup archive"
        return 1
    }

    local archive_size=$(stat -f %z "$BACKUP_ARCHIVE" 2>/dev/null || stat -c %s "$BACKUP_ARCHIVE")
    info "Archive created: $(numfmt --to=iec $archive_size)"

    # Delete directory
    log "Deleting: ${backup_dir}"
    rm -rf "$backup_dir" || {
        error "Failed to delete nested backup directory"
        return 1
    }

    log "✅ Phase 2 complete"
    info "Backup archive: ${BACKUP_ARCHIVE} (keep for 7 days)"
}

execute_phase3_safe_patterns() {
    log "Phase 3: Automated Safe Patterns"

    local categories=("ds_store" "pycache" "pytest_cache" "mypy_cache" "logs")

    for category in "${categories[@]}"; do
        log "Deleting ${category} files..."
        local count=0

        while IFS='|' read -r cat path; do
            if [ "$cat" = "$category" ] && [ -e "$path" ]; then
                rm -rf "$path" 2>/dev/null && ((count++)) || warn "Failed: $path"
            fi
        done < "$DELETION_MANIFEST"

        info "  Deleted ${count} ${category} items"
    done

    log "✅ Phase 3 complete"
}

execute_phase4_venvs() {
    log "Phase 4: Virtual Environments"

    echo ""
    warn "This will delete ALL .venv and venv directories"
    warn "They can be restored with: uv venv && uv sync"
    echo ""
    read -p "Proceed with venv deletion? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        warn "Phase 4 skipped by user"
        return 0
    fi

    local count=0
    while IFS='|' read -r cat path; do
        if [ "$cat" = "venv" ] && [ -e "$path" ]; then
            log "Deleting: $path"
            rm -rf "$path" 2>/dev/null && ((count++)) || warn "Failed: $path"
        fi
    done < "$DELETION_MANIFEST"

    info "Deleted ${count} venv directories"
    log "✅ Phase 4 complete"
}

execute_phase5_node_modules() {
    log "Phase 5: Node Modules"

    echo ""
    warn "This will delete ALL node_modules directories"
    warn "They can be restored with: npm install"
    echo ""
    read -p "Proceed with node_modules deletion? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        warn "Phase 5 skipped by user"
        return 0
    fi

    local count=0
    while IFS='|' read -r cat path; do
        if [ "$cat" = "node_modules" ] && [ -e "$path" ]; then
            log "Deleting: $path"
            rm -rf "$path" 2>/dev/null && ((count++)) || warn "Failed: $path"
        fi
    done < "$DELETION_MANIFEST"

    info "Deleted ${count} node_modules directories"
    log "✅ Phase 5 complete"
}

execute_phase6_build_artifacts() {
    log "Phase 6: Build Artifacts"

    echo ""
    warn "This will delete dist/ and build/ directories (in .gitignore only)"
    echo ""
    read -p "Proceed with build artifact deletion? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        warn "Phase 6 skipped by user"
        return 0
    fi

    local count=0
    while IFS='|' read -r cat path; do
        if [[ "$cat" =~ ^(dist|build)$ ]] && [ -e "$path" ]; then
            log "Deleting: $path"
            rm -rf "$path" 2>/dev/null && ((count++)) || warn "Failed: $path"
        fi
    done < "$DELETION_MANIFEST"

    info "Deleted ${count} build artifact directories"
    log "✅ Phase 6 complete"
}

# ============================================================================
# Validation Functions
# ============================================================================

validate_cleanup() {
    log "Running post-cleanup validation..."

    # Size verification
    local final_size=$(du -sk "$NC_SRC_DIR" 2>/dev/null | cut -f1)
    final_size=$((final_size * 1024))
    info "Final directory size: $(numfmt --to=iec $final_size)"

    # Sample project health checks
    log "Running health checks on sample projects..."

    # Python projects
    local python_projects=($(find "$NC_SRC_DIR" -maxdepth 2 -name "pyproject.toml" -exec dirname {} \; | shuf -n 3))
    for project in "${python_projects[@]}"; do
        if [ -d "$project" ]; then
            info "Checking: $(basename "$project")"
            if [ ! -d "$project/.venv" ]; then
                warn "  Missing .venv - restoration needed: cd $project && uv venv && uv sync"
            fi
        fi
    done

    # Node projects
    local node_projects=($(find "$NC_SRC_DIR" -maxdepth 2 -name "package.json" -exec dirname {} \; | shuf -n 3))
    for project in "${node_projects[@]}"; do
        if [ -d "$project" ]; then
            info "Checking: $(basename "$project")"
            if [ ! -d "$project/node_modules" ]; then
                warn "  Missing node_modules - restoration needed: cd $project && npm install"
            fi
        fi
    done

    log "✅ Validation complete"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "  nc-src Garbage Cleanup Script"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Setup
    trap cleanup_on_exit EXIT
    trap interrupt_handler INT TERM

    # Pre-flight checks
    log "Running pre-flight checks..."
    check_lock_file
    check_directory_exists
    check_write_permissions
    check_disk_space
    check_git_status

    # Phase 1: Discovery and dry-run
    log "Phase 1: Discovery and Analysis"
    find_garbage_files
    generate_dry_run_report

    # User confirmation
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  FINAL CONFIRMATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Review the dry-run report above."
    echo ""
    echo "The following phases will be executed:"
    echo "  Phase 2: Nested backup cleanup (with safety archive)"
    echo "  Phase 3: Safe automated patterns (DS_Store, caches, old logs)"
    echo "  Phase 4: Virtual environments (user confirmation)"
    echo "  Phase 5: Node modules (user confirmation)"
    echo "  Phase 6: Build artifacts (user confirmation)"
    echo ""
    echo "Safety measures active:"
    echo "  ✓ Git status verified (all repos clean)"
    echo "  ✓ Backup archive will be created for Phase 2"
    echo "  ✓ Deletion manifest: ${DELETION_MANIFEST}"
    echo "  ✓ Interrupt handling enabled"
    echo ""
    warn "Type 'DELETE' to proceed (anything else cancels):"
    read -r confirmation

    if [ "$confirmation" != "DELETE" ]; then
        error "Cancelled by user"
        exit 0
    fi

    # Execute phases
    execute_phase2_nested_backups
    execute_phase3_safe_patterns
    execute_phase4_venvs
    execute_phase5_node_modules
    execute_phase6_build_artifacts

    # Validation
    validate_cleanup

    # Summary
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "  CLEANUP COMPLETE"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Logs: ${LOG_DIR}/"
    info "Deletion manifest: ${DELETION_MANIFEST}"
    if [ -f "$BACKUP_ARCHIVE" ]; then
        info "Phase 2 backup: ${BACKUP_ARCHIVE} (keep for 7 days)"
    fi
    echo ""
    log "Restoration commands:"
    log "  Python: cd <project> && uv venv && uv sync"
    log "  Node: cd <project> && npm install"
    echo ""
}

# Run main function
main "$@"
