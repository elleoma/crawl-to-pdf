#!/bin/bash

# Enhanced Website to PDF Converter
# Supports both web crawling and local HTML processing

# set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.0"
readonly MAX_DEPTH=2
readonly MAX_PAGES=100
readonly WEASYPRINT_TIMEOUT=120

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
TEMP_DIR=""
KEEP_TEMP=0
VERBOSE=0
MODE=""
SOURCE=""
OUTPUT_PDF=""

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_verbose() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Help function
show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Enhanced Website to PDF Converter

USAGE:
    $SCRIPT_NAME web <start_url> <output_pdf> [options]
    $SCRIPT_NAME local <html_directory> <output_pdf> [options]

MODES:
    web             Crawl website starting from URL
    local           Process locally saved HTML files

ARGUMENTS:
    start_url       Starting URL for web crawling
    html_directory  Directory containing HTML files for local processing
    output_pdf      Output PDF file path

OPTIONS:
    --keep-temp     Keep temporary files for debugging
    --verbose       Enable verbose output
    --max-depth N   Maximum crawling depth (default: $MAX_DEPTH)
    --max-pages N   Maximum pages to crawl (default: $MAX_PAGES)
    --help          Show this help message

EXAMPLES:
    $SCRIPT_NAME web https://example.com/docs docs.pdf --verbose
    $SCRIPT_NAME local ./saved_website/ website.pdf --keep-temp
    $SCRIPT_NAME web https://en.wikipedia.org/wiki/Main_Page wiki.pdf --max-depth 1

DEPENDENCIES:
    curl, weasyprint, pdfunite (poppler-utils)

EOF
}

# Cleanup function
cleanup_on_signal() {
    local exit_code=$?
    log_warning "Script interrupted, cleaning up..."
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log_verbose "Cleaned up temporary directory: $TEMP_DIR"
    fi
    exit $exit_code
}

# Manual cleanup function
cleanup_temp() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        if [ "$KEEP_TEMP" -eq 0 ]; then
            rm -rf "$TEMP_DIR"
            log_verbose "Cleaned up temporary directory: $TEMP_DIR"
        else
            log_info "Temporary directory preserved: $TEMP_DIR"
        fi
    fi
}

# Set up signal handlers for interruption only
trap cleanup_on_signal INT TERM

# Dependency check
check_dependencies() {
    local missing_deps=()
    
    if [ "$MODE" = "web" ] && ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v weasyprint &> /dev/null; then
        missing_deps+=("weasyprint")
    fi
    
    if ! command -v pdfunite &> /dev/null; then
        missing_deps+=("pdfunite (poppler-utils)")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Please install the required packages and try again."
        exit 1
    fi
}

# Parse command line arguments
parse_arguments() {
    if [ $# -lt 3 ]; then
        show_help
        exit 1
    fi
    
    MODE="$1"
    SOURCE="$2"
    OUTPUT_PDF="$3"
    shift 3
    
    # Validate mode
    if [ "$MODE" != "web" ] && [ "$MODE" != "local" ]; then
        log_error "Invalid mode: $MODE. Use 'web' or 'local'"
        exit 1
    fi
    
    # Parse options
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep-temp)
                KEEP_TEMP=1
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --max-depth)
                if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--max-depth requires a numeric argument"
                    exit 1
                fi
                MAX_DEPTH="$2"
                shift
                ;;
            --max-pages)
                if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--max-pages requires a numeric argument"
                    exit 1
                fi
                MAX_PAGES="$2"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
        shift
    done
}

# Validate inputs
validate_inputs() {
    if [ "$MODE" = "web" ]; then
        if ! [[ "$SOURCE" =~ ^https?:// ]]; then
            log_error "Invalid URL format: $SOURCE"
            exit 1
        fi
    elif [ "$MODE" = "local" ]; then
        if [ ! -d "$SOURCE" ]; then
            log_error "Directory not found: $SOURCE"
            exit 1
        fi
        SOURCE="$(realpath "$SOURCE")"
    fi
    
    # Check if output directory exists
    local output_dir="$(dirname "$OUTPUT_PDF")"
    if [ ! -d "$output_dir" ]; then
        log_error "Output directory does not exist: $output_dir"
        exit 1
    fi
}

# Initialize working environment
init_environment() {
    TEMP_DIR=$(mktemp -d)
    log_verbose "Created temporary directory: $TEMP_DIR"
    
    # Create log files
    mkdir -p "$TEMP_DIR/logs"
    touch "$TEMP_DIR/logs/crawl_errors.log"
    touch "$TEMP_DIR/logs/weasyprint_errors.log"
    touch "$TEMP_DIR/logs/processing.log"
}

# URL normalization functions (for web mode)
normalize_url() {
    local url="$1"
    local base_url="$2"
    local current_url="$3"
    
    if [[ "$url" =~ ^/ ]]; then
        url="$base_url$url"
    elif [[ ! "$url" =~ ^https?:// ]]; then
        url=$(echo "$url" | sed 's|^\./||')
        local current_dir="$(dirname "$current_url" | sed "s|^$base_url||")"
        url="$base_url$current_dir/$url"
    fi
    
    # Clean up URL
    url=$(echo "$url" | sed 's/#.*$//; s|/$||; s/\?.*$//')
    echo "$url"
}

url_to_filepath() {
    local url="$1"
    local base_url="$2"
    local domain="$3"
    
    local path=$(echo "$url" | sed "s|^$base_url/||; s|/$||; s|/|_|g")
    if [ -z "$path" ]; then
        path="index"
    fi
    echo "$TEMP_DIR/$domain/$path.html"
}

calculate_depth() {
    local url="$1"
    local path=$(echo "$url" | sed "s|^https\?://[^/]*||; s|^/||; s|/$||")
    if [ -z "$path" ]; then
        echo 0
    else
        echo "$path" | awk -F'/' '{print NF}'
    fi
}

# Web crawling function
crawl_website() {
    local start_url="$SOURCE"
    local domain=$(echo "$start_url" | grep -oE '(https?://[^/]+)' | sed 's|https\?://||')
    local base_url=$(echo "$start_url" | grep -oE 'https?://[^/]+')
    
    log_info "Starting web crawl from: $start_url"
    log_info "Domain: $domain, Max depth: $MAX_DEPTH, Max pages: $MAX_PAGES"
    
    local queue_file="$TEMP_DIR/queue.txt"
    local visited_file="$TEMP_DIR/visited.txt"
    local crawl_log="$TEMP_DIR/logs/crawl_errors.log"
    
    echo "$start_url" > "$queue_file"
    touch "$visited_file"
    
    mkdir -p "$TEMP_DIR/$domain"
    
    local page_count=0
    
    while [ -s "$queue_file" ] && [ "$page_count" -lt "$MAX_PAGES" ]; do
        local current_url=$(head -n 1 "$queue_file")
        sed -i '1d' "$queue_file"
        
        if grep -Fx "$current_url" "$visited_file" >/dev/null; then
            log_verbose "Skipping already visited: $current_url"
            continue
        fi
        
        echo "$current_url" >> "$visited_file"
        
        local depth=$(calculate_depth "$current_url")
        log_verbose "Processing $current_url (depth $depth)"
        
        if [ "$depth" -gt "$MAX_DEPTH" ]; then
            log_verbose "Skipping (depth $depth > $MAX_DEPTH): $current_url"
            continue
        fi
        
        local file_path=$(url_to_filepath "$current_url" "$base_url" "$domain")
        log_verbose "Downloading $current_url to $file_path"
        
        if curl -s -L --fail --retry 3 --retry-delay 2 --max-time 30 "$current_url" > "$file_path" 2>> "$crawl_log"; then
            ((page_count++))
            log_info "Crawled page $page_count: $current_url"
            
            # Extract and process links
            local links=$(grep -o '<a[^>]*href=["\047][^"\047]*["\047]' "$file_path" 2>/dev/null | sed 's/.*href=["\047]\([^"\047]*\)["\047].*/\1/' | sort -u)
            
            for link in $links; do
                if [ -z "$link" ] || [[ "$link" =~ ^(javascript:|mailto:|#|data:) ]]; then
                    continue
                fi
                
                local normalized_link=$(normalize_url "$link" "$base_url" "$current_url")
                
                if [[ "$normalized_link" =~ ^https?://$domain ]]; then
                    local local_path=$(url_to_filepath "$normalized_link" "$base_url" "$domain")
                    local relative_path=$(realpath --relative-to="$(dirname "$file_path")" "$local_path" 2>/dev/null || echo "$local_path")
                    
                    # Update link in HTML file
                    local escaped_link=$(echo "$link" | sed 's/[&]/\\&/g; s/[[\.*^$(){}+?|\\]/\\&/g')
                    sed -i "s|href=[\"']${escaped_link}[\"']|href=\"$relative_path\"|g" "$file_path" 2>> "$crawl_log"
                    
                    if ! grep -Fx "$normalized_link" "$visited_file" >/dev/null; then
                        echo "$normalized_link" >> "$queue_file"
                        log_verbose "Queued: $normalized_link"
                    fi
                fi
            done
        else
            log_warning "Failed to download $current_url"
        fi
    done
    
    log_success "Crawled $page_count pages"
}

# Local HTML processing function
process_local_html() {
    local html_dir="$SOURCE"
    log_info "Processing local HTML files from: $html_dir"
    
    # Find all HTML files recursively
    local html_files=()
    while IFS= read -r -d '' file; do
        html_files+=("$file")
    done < <(find "$html_dir" -type f \( -name "*.html" -o -name "*.htm" \) -print0)
    
    if [ ${#html_files[@]} -eq 0 ]; then
        log_error "No HTML files found in $html_dir"
        exit 1
    fi
    
    log_info "Found ${#html_files[@]} HTML files"
    
    # Copy HTML files to temp directory, maintaining structure
    local temp_html_dir="$TEMP_DIR/html"
    mkdir -p "$temp_html_dir"
    
    for html_file in "${html_files[@]}"; do
        local rel_path=$(realpath --relative-to="$html_dir" "$html_file")
        local dest_path="$temp_html_dir/$rel_path"
        local dest_dir=$(dirname "$dest_path")
        
        mkdir -p "$dest_dir"
        cp "$html_file" "$dest_path"
        log_verbose "Copied: $rel_path"
    done
    
    # Also copy any associated assets (CSS, JS, images)
    local asset_extensions=("css" "js" "png" "jpg" "jpeg" "gif" "svg" "ico" "woff" "woff2" "ttf" "eot")
    for ext in "${asset_extensions[@]}"; do
        while IFS= read -r -d '' file; do
            local rel_path=$(realpath --relative-to="$html_dir" "$file")
            local dest_path="$temp_html_dir/$rel_path"
            local dest_dir=$(dirname "$dest_path")
            
            mkdir -p "$dest_dir"
            cp "$file" "$dest_path"
            log_verbose "Copied asset: $rel_path"
        done < <(find "$html_dir" -type f -name "*.${ext}" -print0 2>/dev/null)
    done
    
    log_success "Processed local HTML files"
}

# Try alternative conversion for problematic files
try_alternative_conversion() {
    local html_file="$1"
    local pdf_file="$2"
    local html_dir="$3"
    local weasyprint_log="$4"
    
    log_verbose "Trying alternative conversion for $(basename "$html_file")"
    
    # Try with simpler options (no base URL, different media type)
    if timeout 30 weasyprint \
        --media-type screen \
        --pdf-version 1.4 \
        "$html_file" "$pdf_file" 2>> "$weasyprint_log"; then
        return 0
    fi
    
    # Try with minimal options
    if timeout 30 weasyprint \
        "$html_file" "$pdf_file" 2>> "$weasyprint_log"; then
        return 0
    fi
    
    return 1
}

# PDF generation function
generate_pdfs() {
    local html_files=()
    local pdf_files=()

    # Find HTML files in temp directory
    while IFS= read -r -d '' file; do
        html_files+=("$file")
    done < <(find "$TEMP_DIR" -type f \( -name "*.html" -o -name "*.htm" \) -print0)

    if [ ${#html_files[@]} -eq 0 ]; then
        log_error "No HTML files found for PDF generation"
        exit 1
    fi

    # Sort files for consistent processing order
    IFS=$'\n' html_files=($(sort <<<"${html_files[*]}"))
    unset IFS

    log_info "Converting ${#html_files[@]} HTML files to PDF"

    local success_count=0
    local failed_count=0
    local current_file=0
    local weasyprint_log="$TEMP_DIR/logs/weasyprint_errors.log"

    for html_file in "${html_files[@]}"; do
        ((current_file++))
        local html_dir=$(dirname "$html_file")
        local pdf_file="${html_file%.html}.pdf"
        pdf_file="${pdf_file%.htm}.pdf"
        local filename=$(basename "$html_file")

        log_info "[$current_file/${#html_files[@]}] Converting $filename to PDF..."

        local start_time=$(date +%s)

        log_verbose "Running WeasyPrint on: $html_file"
        if timeout "$WEASYPRINT_TIMEOUT" weasyprint \
            --base-url "file://$html_dir/" \
            --media-type print \
            --pdf-version 1.7 \
            --verbose \
            "$html_file" "$pdf_file" 2>> "$weasyprint_log"; then

            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            if [ -f "$pdf_file" ] && [ -s "$pdf_file" ]; then
                pdf_files+=("$pdf_file")
                ((success_count++))
                log_success "✓ $filename converted successfully (${duration}s)"
            else
                log_warning "✗ $filename: PDF file is empty or missing"
                ((failed_count++))
            fi
        else
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            if [ $duration -ge $WEASYPRINT_TIMEOUT ]; then
                log_warning "✗ $filename: Conversion timed out after ${WEASYPRINT_TIMEOUT}s"
            else
                log_warning "✗ $filename: Conversion failed (${duration}s)"
            fi

            # Try alternative conversion
            if try_alternative_conversion "$html_file" "$pdf_file" "$html_dir" "$weasyprint_log"; then
                if [ -f "$pdf_file" ] && [ -s "$pdf_file" ]; then
                    pdf_files+=("$pdf_file")
                    ((success_count++))
                    log_success "✓ $filename converted with alternative method"
                else
                    ((failed_count++))
                fi
            else
                ((failed_count++))
            fi
        fi

        # Show progress
        if [ $((current_file % 10)) -eq 0 ] || [ $current_file -eq ${#html_files[@]} ]; then
            log_info "Progress: $current_file/${#html_files[@]} (Success: $success_count, Failed: $failed_count)"
        fi
    done

    if [ ${#pdf_files[@]} -eq 0 ]; then
        log_error "No PDFs were generated successfully"
        exit 1
    fi

    log_success "Generated $success_count PDFs successfully"
    if [ $failed_count -gt 0 ]; then
        log_warning "$failed_count files failed to convert"
    fi

    # Merge PDFs
    log_info "Merging ${#pdf_files[@]} PDFs into $OUTPUT_PDF..."
    if pdfunite "${pdf_files[@]}" "$OUTPUT_PDF" 2>> "$TEMP_DIR/logs/processing.log"; then
        log_success "Successfully created $OUTPUT_PDF"
        if command -v du &> /dev/null; then
            local file_size=$(du -h "$OUTPUT_PDF" | cut -f1)
            log_info "Final PDF size: $file_size"
        fi
    else
        log_error "Failed to merge PDFs"
        exit 1
    fi
}

# Copy debug files
copy_debug_files() {
    local debug_files=(
        "crawl_errors.log"
        "weasyprint_errors.log"
        "processing.log"
    )
    
    for file in "${debug_files[@]}"; do
        if [ -f "$TEMP_DIR/logs/$file" ]; then
            cp "$TEMP_DIR/logs/$file" "./$file"
        fi
    done
    
    # Copy other useful files
    if [ -f "$TEMP_DIR/queue.txt" ]; then
        cp "$TEMP_DIR/queue.txt" "./queue.log"
    fi
    
    if [ -f "$TEMP_DIR/visited.txt" ]; then
        cp "$TEMP_DIR/visited.txt" "./visited.log"
    fi
    
    log_info "Debug files saved to current directory"
}

# Main function
main() {
    log_info "$SCRIPT_NAME v$VERSION starting..."
    
    parse_arguments "$@"
    validate_inputs
    check_dependencies
    init_environment
    
    if [ "$MODE" = "web" ]; then
        crawl_website
    elif [ "$MODE" = "local" ]; then
        process_local_html
    fi
    
    generate_pdfs
    copy_debug_files
    cleanup_temp
    
    log_success "Process completed successfully!"
    log_info "Output: $OUTPUT_PDF"

    # Sort files for consistent processing order
    IFS=$'\n' html_files=($(sort <<<"${html_files[*]}"))
    unset IFS    
    log_info "Converting ${#html_files[@]} HTML files to PDF"
    
    local success_count=0
    local failed_count=0
    local current_file=0
    local weasyprint_log="$TEMP_DIR/logs/weasyprint_errors.log"
    
    for html_file in "${html_files[@]}"; do
        ((current_file++))
        local html_dir=$(dirname "$html_file")
        local pdf_file="${html_file%.html}.pdf"
        pdf_file="${pdf_file%.htm}.pdf"
        local filename=$(basename "$html_file")
        
        log_info "[$current_file/${#html_files[@]}] Converting $filename to PDF..."
        
        # Add progress indicators and better error handling
        local start_time=$(date +%s)
        
        if timeout "$WEASYPRINT_TIMEOUT" weasyprint \
            --base-url "file://$html_dir/" \
            --media-type print \
            --pdf-version 1.7 \
            --verbose \
            "$html_file" "$pdf_file" 2>> "$weasyprint_log"; then
            
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            
            if [ -f "$pdf_file" ] && [ -s "$pdf_file" ]; then
                pdf_files+=("$pdf_file")
                ((success_count++))
                log_success "✓ $filename converted successfully (${duration}s)"
            else
                log_warning "✗ $filename: PDF file is empty or missing"
                ((failed_count++))
            fi
        else
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            
            if [ $duration -ge $WEASYPRINT_TIMEOUT ]; then
                log_warning "✗ $filename: Conversion timed out after ${WEASYPRINT_TIMEOUT}s"
            else
                log_warning "✗ $filename: Conversion failed (${duration}s)"
            fi
            
            # Try alternative conversion method
            log_verbose "Attempting alternative conversion for $filename"
            if try_alternative_conversion "$html_file" "$pdf_file" "$html_dir" "$weasyprint_log"; then
                if [ -f "$pdf_file" ] && [ -s "$pdf_file" ]; then
                    pdf_files+=("$pdf_file")
                    ((success_count++))
                    log_success "✓ $filename converted with alternative method"
                else
                    ((failed_count++))
                fi
            else
                ((failed_count++))
            fi
            
            # Log the last few lines of the error for this file
            echo "=== Error for $filename ===" >> "$weasyprint_log"
            tail -n 10 "$weasyprint_log" >> "$weasyprint_log"
        fi
        
        # Show progress
        if [ $((current_file % 10)) -eq 0 ] || [ $current_file -eq ${#html_files[@]} ]; then
            log_info "Progress: $current_file/${#html_files[@]} files processed (Success: $success_count, Failed: $failed_count)"
        fi
    done
    
    if [ ${#pdf_files[@]} -eq 0 ]; then
        log_error "No PDFs were generated successfully"
        log_error "Check weasyprint_errors.log for details"
        exit 1
    fi
    
    log_success "Generated $success_count PDFs successfully"
    if [ $failed_count -gt 0 ]; then
        log_warning "$failed_count files failed to convert"
    fi
    
    # Merge PDFs
    log_info "Merging ${#pdf_files[@]} PDFs into $OUTPUT_PDF..."
    
    if pdfunite "${pdf_files[@]}" "$OUTPUT_PDF" 2>> "$TEMP_DIR/logs/processing.log"; then
        log_success "Successfully created $OUTPUT_PDF"
        
        # Show final file info
        if command -v du &> /dev/null; then
            local file_size=$(du -h "$OUTPUT_PDF" | cut -f1)
            log_info "Final PDF size: $file_size"
        fi
    else
        log_error "Failed to merge PDFs"
        log_error "Check processing.log for details"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"
