#!/bin/bash
set -e

# Usage: ./generate_with_az_rest.sh [PROMPT] [OUTPUT_FILE] [SIZE] [INPUT_IMAGE]
# 
# Generate a new image from a text prompt:
#   ./generate_with_az_rest.sh "a sunset over mountains"
#   ./generate_with_az_rest.sh "a dog playing" "assets/dog.png"
#   ./generate_with_az_rest.sh "abstract art" "output/art.png" "1024x1024"
#
# Edit an existing image with a prompt:
#   ./generate_with_az_rest.sh "add sunglasses" "assets/cool_cat.png" "1024x1024" "assets/cat.png"

# Configuration variables
PROMPT="${1:-photo realistic image of a cat typing on a laptop}"
OUTPUT_FILE="${2:-assets/cat_typing_laptop.png}"
SIZE="${3:-1024x1024}"
INPUT_IMAGE="${4:-}"

# Azure resource configuration
RESOURCE_HOST="cloudnativelinz-poland-resource.openai.azure.com"
DEPLOYMENT="gpt-image-1.5"

echo "Generating image with Azure OpenAI..."
echo "Prompt: $PROMPT"
echo "Output: $OUTPUT_FILE"
echo "Size: $SIZE"
if [ -n "$INPUT_IMAGE" ]; then
    if [ ! -f "$INPUT_IMAGE" ]; then
        echo "❌ Error: Input image not found: $INPUT_IMAGE"
        exit 1
    fi
    echo "Input: $INPUT_IMAGE (image edit mode)"
fi
echo ""

# Create output directory if it doesn't exist
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
mkdir -p "$OUTPUT_DIR"

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

if [ -n "$INPUT_IMAGE" ]; then
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
else
    # ── Text-to-Image Generation Mode ──
    # Uses /images/generations endpoint with JSON body
    API_VERSION="2024-02-01"
    ENDPOINT="https://${RESOURCE_HOST}/openai/deployments/${DEPLOYMENT}/images/generations"

    echo "Using image generations endpoint (api-version: $API_VERSION)..."
    response=$(az rest \
        --method POST \
        --url "${ENDPOINT}?api-version=${API_VERSION}" \
        --resource "https://cognitiveservices.azure.com" \
        --headers "Content-Type=application/json" \
        --body "{\"prompt\":\"$PROMPT\",\"n\":1,\"size\":\"$SIZE\"}" \
        2>&1)

    if echo "$response" | grep -q '"b64_json"'; then
        echo "✅ Image generation successful"
        echo "$response" | save_image
    else
        echo "❌ Image generation failed"
        echo "$response" | head -c 500
        exit 1
    fi
fi
