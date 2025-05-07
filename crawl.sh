#!/bin/bash

# Usage: ./crawl_to_pdf.sh <start_url> <max_depth> <output_pdf>
# Example: ./crawl_to_pdf.sh https://en.wikipedia.org/wiki/Main_Page 2 wikipedia.pdf

# Check if required arguments are provided
if [ $# -ne 3 ]; then
    echo "Usage: $0 <start_url> <max_depth> <output_pdf>"
    echo "Example: $0 https://en.wikipedia.org/wiki/Main_Page 2 wikipedia.pdf"
    exit 1
fi

START_URL="$1"
MAX_DEPTH="$2"
OUTPUT_PDF="$3"

# Validate max_depth is a positive integer
if ! [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] || [ "$MAX_DEPTH" -lt 1 ]; then
    echo "Error: max_depth must be a positive integer."
    exit 1
fi

# Check if wget, weasyprint, and pdfunite are installed
if ! command -v wget &> /dev/null; then
    echo "Error: wget is not installed."
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

# Create a temporary directory for downloads
TEMP_DIR=$(mktemp -d)
echo "Working in temporary directory: $TEMP_DIR"

# Extract domain from URL to restrict crawling
DOMAIN=$(echo "$START_URL" | grep -oP '(?<=://)[^/]+')

# Crawl the website using wget
echo "Crawling $START_URL (max depth: $MAX_DEPTH)..."
wget \
    --recursive \
    --level="$MAX_DEPTH" \
    --convert-links \
    --html-extension \
    --no-parent \
    --domains="$DOMAIN" \
    --no-verbose \
    --directory-prefix="$TEMP_DIR" \
    "$START_URL"

if [ $? -ne 0 ]; then
    echo "Error: Failed to crawl $START_URL."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Generate file_list.txt with all HTML files
echo "Generating list of HTML files..."
find "$TEMP_DIR" -type f -name "*.html" > "$TEMP_DIR/file_list.txt"

# Check if file_list.txt was generated successfully
if [ ! -s "$TEMP_DIR/file_list.txt" ]; then
    echo "Error: No HTML files found."
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Found $(wc -l < "$TEMP_DIR/file_list.txt") HTML files."

# Array to store generated PDF files
pdf_files=()

# Convert each HTML file to PDF
while IFS= read -r html_file; do
    # Get the directory containing the HTML file
    html_dir=$(dirname "$html_file")
    
    # Check if the HTML file exists
    if [ ! -f "$html_file" ]; then
        echo "Warning: $html_file not found, skipping."
        continue
    fi
    
    # Define the output PDF for each HTML file
    pdf_file="${html_file%.html}.pdf"
    
    # Convert HTML to PDF using weasyprint
    echo "Converting $html_file to PDF..."
    weasyprint \
        --base-url "file://$html_dir/" \
        --media-type print \
        "$html_file" "$pdf_file"
    
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to convert $html_file to PDF, skipping."
        continue
    fi
    
    # Add the PDF to the array
    pdf_files+=("$pdf_file")
done < "$TEMP_DIR/file_list.txt"

# Check if any PDFs were generated
if [ ${#pdf_files[@]} -eq 0 ]; then
    echo "Error: No PDFs were generated."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Merge the PDFs into a single file
echo "Merging PDFs into $OUTPUT_PDF..."
pdfunite "${pdf_files[@]}" "$OUTPUT_PDF"

if [ $? -eq 0 ]; then
    echo "Successfully created $OUTPUT_PDF"
else
    echo "Error merging PDFs."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Clean up temporary directory
rm -rf "$TEMP_DIR"
echo "Cleaned up temporary files."
