#!/bin/bash
set -e

# Usage: ./generate_with_az_rest.sh -p PROMPT -i INPUT_IMAGE [-s SIZE]
#
# Required:
#   -p PROMPT        The text prompt for image generation/editing
#   -i INPUT_IMAGE   The input image file (used for edit mode; output name derived from this)
#
# Optional:
#   -s SIZE          Image size (default: 1024x1024)
#
# The output file is auto-generated from the input image name with "_generated" appended.
# Example: input "assets/cat.png" → output "assets/cat_generated.png"
#
# Examples:
#   ./generate_with_az_rest.sh -p "add sunglasses" -i "assets/cat.png"
#   ./generate_with_az_rest.sh -p "make it pop art style" -i "photos/portrait.jpg" -s "1024x1536"

# Defaults
PROMPT=""
INPUT_IMAGE=""
SIZE="1024x1024"

# Parse named arguments
while getopts "p:i:s:" opt; do
    case $opt in
        p) PROMPT="$OPTARG" ;;
        i) INPUT_IMAGE="$OPTARG" ;;
        s) SIZE="$OPTARG" ;;
        *) echo "Usage: $0 -p PROMPT -i INPUT_IMAGE [-s SIZE]"; exit 1 ;;
    esac
done

# Validate required arguments
if [ -z "$PROMPT" ]; then
    echo "❌ Error: Prompt is required (-p)"
    echo "Usage: $0 -p PROMPT -i INPUT_IMAGE [-s SIZE]"
    exit 1
fi

if [ -z "$INPUT_IMAGE" ]; then
    echo "❌ Error: Input image is required (-i)"
    echo "Usage: $0 -p PROMPT -i INPUT_IMAGE [-s SIZE]"
    exit 1
fi

if [ ! -f "$INPUT_IMAGE" ]; then
    echo "❌ Error: Input image not found: $INPUT_IMAGE"
    exit 1
fi

# Derive output file: append "_generated" before the file extension
INPUT_DIR=$(dirname "$INPUT_IMAGE")
INPUT_BASENAME=$(basename "$INPUT_IMAGE")
INPUT_NAME="${INPUT_BASENAME%.*}"
INPUT_EXT="${INPUT_BASENAME##*.}"
OUTPUT_FILE="${INPUT_DIR}/${INPUT_NAME}_generated.${INPUT_EXT}"

# Azure resource configuration
RESOURCE_HOST="cloudnativelinz-poland-resource.openai.azure.com"
DEPLOYMENT="gpt-image-1.5"

echo "Generating image with Azure OpenAI..."
echo "Prompt:  $PROMPT"
echo "Input:   $INPUT_IMAGE"
echo "Output:  $OUTPUT_FILE"
echo "Size:    $SIZE"
echo ""

# Create output directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Helper: decode base64 image from JSON response and save to file
save_image() {
    python3 -c "
import sys, json, base64
from pathlib import Path
data = json.load(sys.stdin)
if 'data' in data and len(data['data']) > 0 and 'b64_json' in data['data'][0]:
    image_data = base64.b64decode(data['data'][0]['b64_json'])
    output_path = Path('$OUTPUT_FILE')
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(image_data)
    print(f'Image saved to $OUTPUT_FILE')
    print(f'Size: {len(image_data) / (1024*1024):.2f} MB')
else:
    print('Error: No image data in response', file=sys.stderr)
    sys.exit(1)
"
}

# ── Image Edit Mode ──
# Uses /images/edits endpoint with multipart/form-data (requires 2025-04-01-preview+)
API_VERSION="2025-04-01-preview"
ENDPOINT="https://${RESOURCE_HOST}/openai/deployments/${DEPLOYMENT}/images/edits"
TOKEN=$(az account get-access-token --resource "https://cognitiveservices.azure.com" --query accessToken -o tsv)

echo "Using image edits endpoint (api-version: $API_VERSION)..."
response=$(curl -s --max-time 300 -X POST \
    "${ENDPOINT}?api-version=${API_VERSION}" \
    -H "Authorization: Bearer $TOKEN" \
    -F "image=@$INPUT_IMAGE" \
    -F "prompt=$PROMPT" \
    -F "n=1" \
    -F "size=$SIZE" \
    2>&1)

if echo "$response" | grep -q '"b64_json"'; then
    echo "✅ Image edit successful"
    echo "$response" | save_image
else
    echo "❌ Image edit failed"
    echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('error',d),indent=2))" 2>/dev/null || echo "$response" | head -c 500
    exit 1
fi
