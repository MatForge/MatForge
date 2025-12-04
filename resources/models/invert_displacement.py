#!/usr/bin/env python3
"""
Invert Displacement Map Tool

Inverts the height values in a displacement map (grayscale image).
Black becomes white, white becomes black.

Usage:
    python invert_displacement.py <input_image_path>

Output:
    Creates an inverted image with '_inv' suffix in the same directory
    Example: displacement_512.png -> displacement_512_inv.png

Author: MatForge Team (CIS 5650 Fall 2025)
"""

import sys
import os
from pathlib import Path

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("Error: Required libraries not found.")
    print("Please install: pip install pillow numpy")
    sys.exit(1)


def invert_displacement_map(input_path):
    """
    Inverts a displacement map by flipping the grayscale values.

    Args:
        input_path: Path to the input displacement map image

    Returns:
        Path to the output inverted image
    """
    input_path = Path(input_path)

    # Validate input file exists
    if not input_path.exists():
        raise FileNotFoundError(f"Input file not found: {input_path}")

    # Load the image
    print(f"Loading displacement map: {input_path}")
    img = Image.open(input_path)

    # Convert to numpy array for processing
    img_array = np.array(img)

    # Get the maximum value based on dtype
    if img_array.dtype == np.uint8:
        max_value = 255
    elif img_array.dtype == np.uint16:
        max_value = 65535
    else:
        # For float images, assume normalized [0, 1]
        max_value = 1.0

    # Invert the values
    inverted_array = max_value - img_array

    # Convert back to PIL Image
    inverted_img = Image.fromarray(inverted_array)

    # Preserve the original mode (L for grayscale, RGB for color, etc.)
    if inverted_img.mode != img.mode:
        inverted_img = inverted_img.convert(img.mode)

    # Generate output filename with '_inv' suffix
    output_path = input_path.parent / f"{input_path.stem}_inv{input_path.suffix}"

    # Save the inverted image
    print(f"Saving inverted displacement map: {output_path}")
    inverted_img.save(output_path)

    print(f"[SUCCESS] Successfully created inverted displacement map")
    print(f"  Input:  {input_path}")
    print(f"  Output: {output_path}")
    print(f"  Size:   {img.width}x{img.height}")
    print(f"  Mode:   {img.mode}")
    print(f"  Depth:  {img_array.dtype}")

    return output_path


def main():
    """Main entry point for the script."""
    if len(sys.argv) != 2:
        print("Usage: python invert_displacement.py <input_image_path>")
        print()
        print("Example:")
        print("  python invert_displacement.py ../resources/models/displacement_512.png")
        sys.exit(1)

    input_image = sys.argv[1]

    try:
        invert_displacement_map(input_image)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
