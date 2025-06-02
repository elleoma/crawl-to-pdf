#!/bin/bash

if [ $# -lt 2 ]; then
    echo "Usage: $0 <start_url> <output_pdf> [--keep-temp]"
    echo "Example: $0 https://en.wikipedia.org/wiki/Main_Page wikipedia.pdf --keep-temp"
    exit 1
fi

START_URL="$1"
OUTPUT_PDF="$2"
KEEP_TEMP=0
if [ "$3" = "--keep-temp" ]; then
    KEEP_TEMP=1
fi

if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed."
    exit 1
fi
if ! command -v weasyprint &> /dev/null; then
    echo "Error: weasyprint is not installed."
    exit 1
fi
if ! command -v pdfunite &> /dev/null; then
    echo "Error: pdfunite is not installed."
    exit 1
fi

TEMP_DIR=$(mktemp -d)
echo "Working in temporary directory: $TEMP_DIR"

DOMAIN=$(echo "$START_URL" | grep -oE '(https?://[^/]+)' | sed 's|https\?://||')
BASE_URL=$(echo "$START_URL" | grep -oE 'https?://[^/]+')

QUEUE_FILE="$TEMP_DIR/queue.txt"
VISITED_FILE="$TEMP_DIR/visited.txt"
CRAWL_ERROR_LOG="$TEMP_DIR/crawl_errors.log"
WEASYPRINT_ERROR_LOG="$TEMP_DIR/weasyprint_errors.log"
echo "$START_URL" > "$QUEUE_FILE"
touch "$VISITED_FILE" "$CRAWL_ERROR_LOG" "$WEASYPRINT_ERROR_LOG"

MAX_DEPTH=2
MAX_PAGES=100
PAGE_COUNT=0

mkdir -p "$TEMP_DIR/$DOMAIN"

normalize_url() {
    local url="$1"
    local base="$2"
    if [[ "$url" =~ ^/ ]]; then
        url="$BASE_URL$url"
    elif [[ ! "$url" =~ ^https?:// ]]; then
        url=$(echo "$url" | sed 's|^\./||')
        url="$BASE_URL/$(dirname "$base" | sed "s|^$BASE_URL||")/$url"
    fi
    url=$(echo "$url" | sed 's/#.*$//; s|/$||; s/\?.*$//')
    echo "$url"
}

url_to_filepath() {
    local url="$1"
    local path=$(echo "$url" | sed "s|^$BASE_URL/||; s|/$||; s|/|_|g")
    if [ -z "$path" ]; then
        path="index"
    fi
    echo "$TEMP_DIR/$DOMAIN/$path.html"
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

echo "Crawling $START_URL (links within $DOMAIN, max depth $MAX_DEPTH, max pages $MAX_PAGES)..."
while [ -s "$QUEUE_FILE" ] && [ "$PAGE_COUNT" -lt "$MAX_PAGES" ]; do
    CURRENT_URL=$(head -n 1 "$QUEUE_FILE")
    sed -i '1d' "$QUEUE_FILE"

    if grep -Fx "$CURRENT_URL" "$VISITED_FILE" >/dev/null; then
        echo "Skipping already visited: $CURRENT_URL" >> "$CRAWL_ERROR_LOG"
        continue
    fi

    echo "$CURRENT_URL" >> "$VISITED_FILE"

    DEPTH=$(calculate_depth "$CURRENT_URL")
    echo "Processing $CURRENT_URL (depth $DEPTH)" >> "$CRAWL_ERROR_LOG"
    if [ "$DEPTH" -gt "$MAX_DEPTH" ]; then
        echo "Skipping (depth $DEPTH > $MAX_DEPTH): $CURRENT_URL" >> "$CRAWL_ERROR_LOG"
        continue
    fi

    FILE_PATH=$(url_to_filepath "$CURRENT_URL")
    echo "Downloading $CURRENT_URL to $FILE_PATH..."
    curl -s -L --fail --retry 3 --retry-delay 2 "$CURRENT_URL" > "$FILE_PATH" 2>> "$CRAWL_ERROR_LOG"
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to download $CURRENT_URL" >> "$CRAWL_ERROR_LOG"
        continue
    fi

    ((PAGE_COUNT++))
    echo "Crawled page $PAGE_COUNT: $CURRENT_URL"

    LINKS=$(grep -o '<a[^>]*href=["'"'"'][^"'"'"']*["'"'"']' "$FILE_PATH" | sed 's/.*href=["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/' | sort -u)
    for LINK in $LINKS; do
        if [ -z "$LINK" ] || [[ "$LINK" =~ ^(javascript:|mailto:|#|data:) ]]; then
            continue
        fi

        NORMALIZED_LINK=$(normalize_url "$LINK" "$CURRENT_URL")
        
        if [[ "$NORMALIZED_LINK" =~ ^https?://$DOMAIN ]]; then
            LOCAL_PATH=$(url_to_filepath "$NORMALIZED_LINK")
            RELATIVE_PATH=$(realpath --relative-to="$(dirname "$FILE_PATH")" "$LOCAL_PATH" 2>/dev/null || echo "$LOCAL_PATH")
            
            ESCAPED_LINK=$(echo "$LINK" | sed 's/[&]/\\&/g')
            sed -i "s|href=[\"']${ESCAPED_LINK}[\"']|href=\"$RELATIVE_PATH\"|g" "$FILE_PATH" 2>> "$CRAWL_ERROR_LOG"
            
            if ! grep -Fx "$NORMALIZED_LINK" "$VISITED_FILE" >/dev/null; then
                echo "$NORMALIZED_LINK" >> "$QUEUE_FILE"
                echo "Queued: $NORMALIZED_LINK" >> "$CRAWL_ERROR_LOG"
            fi
        fi
    done
done

echo "Generating list of HTML files..."
find "$TEMP_DIR" -type f \( -name "*.html" -o -name "*.htm" \) > "$TEMP_DIR/file_list.txt"

if [ ! -s "$TEMP_DIR/file_list.txt" ]; then
    echo "Error: No HTML files found. Check crawl_errors.log for details."
    cp "$CRAWL_ERROR_LOG" "./crawl_errors.log"
    cp "$WEASYPRINT_ERROR_LOG" "./weasyprint_errors.log"
    cp "$QUEUE_FILE" "./queue.log" 2>/dev/null
    cp "$VISITED_FILE" "./visited.log" 2>/dev/null
    cp "$TEMP_DIR/file_list.txt" "./file_list.log" 2>/dev/null
    if [ $KEEP_TEMP -eq 0 ]; then
        rm -rf "$TEMP_DIR"
    else
        echo "Temporary directory preserved: $TEMP_DIR"
    fi
    exit 1
fi

echo "Found $(wc -l < "$TEMP_DIR/file_list.txt") HTML files."

pdf_files=()

while IFS= read -r html_file; do
    html_dir=$(dirname "$html_file")
    
    if [ ! -f "$html_file" ]; then
        echo "Warning: $html_file not found, skipping." >> "$WEASYPRINT_ERROR_LOG"
        continue
    fi
    
    pdf_file="${html_file%.html}.pdf"
    pdf_file="${pdf_file%.htm}.pdf"
    
    echo "Converting $html_file to PDF..."
    weasyprint \
        --base-url "file://$html_dir/" \
        --media-type print \
        "$html_file" "$pdf_file" 2>> "$WEASYPRINT_ERROR_LOG"
    
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to convert $html_file to PDF, see weasyprint_errors.log for details." >> "$WEASYPRINT_ERROR_LOG"
        continue
    fi
    
    pdf_files+=("$pdf_file")
done < "$TEMP_DIR/file_list.txt"

if [ ${#pdf_files[@]} -eq 0 ]; then
    echo "Error: No PDFs were generated. Check weasyprint_errors.log for details."
    cp "$CRAWL_ERROR_LOG" "./crawl_errors.log"
    cp "$WEASYPRINT_ERROR_LOG" "./weasyprint_errors.log"
    cp "$QUEUE_FILE" "./queue.log" 2>/dev/null
    cp "$VISITED_FILE" "./visited.log" 2>/dev/null
    cp "$TEMP_DIR/file_list.txt" "./file_list.log" 2>/dev/null
    if [ $KEEP_TEMP -eq 0 ]; then
        rm -rf "$TEMP_DIR"
    else
        echo "Temporary directory preserved: $TEMP_DIR"
    fi
    exit 1
fi

echo "Generated ${#pdf_files[@]} PDFs."

echo "Merging PDFs into $OUTPUT_PDF..."
pdfunite "${pdf_files[@]}" "$OUTPUT_PDF"

if [ $? -eq 0 ]; then
    echo "Successfully created $OUTPUT_PDF"
else
    echo "Error merging PDFs."
    cp "$CRAWL_ERROR_LOG" "./crawl_errors.log"
    cp "$WEASYPRINT_ERROR_LOG" "./weasyprint_errors.log"
    cp "$QUEUE_FILE" "./queue.log" 2>/dev/null
    cp "$VISITED_FILE" "./visited.log" 2>/dev/null
    cp "$TEMP_DIR/file_list.txt" "./file_list.log" 2>/dev/null
    if [ $KEEP_TEMP -eq 0 ]; then
        rm -rf "$TEMP_DIR"
    else
        echo "Temporary directory preserved: $TEMP_DIR"
    fi
    exit 1
fi

cp "$CRAWL_ERROR_LOG" "./crawl_errors.log"
cp "$WEASYPRINT_ERROR_LOG" "./weasyprint_errors.log"
cp "$QUEUE_FILE" "./queue.log" 2>/dev/null
cp "$VISITED_FILE" "./visited.log" 2>/dev/null
cp "$TEMP_DIR/file_list.txt" "./file_list.log" 2>/dev/null
echo "Debug files saved: crawl_errors.log, weasyprint_errors.log, queue.log, visited.log, file_list.log"

if [ $KEEP_TEMP -eq 0 ]; then
    rm -rf "$TEMP_DIR"
    echo "Cleaned up temporary files."
else
    echo "Temporary directory preserved: $TEMP_DIR"
fi
