#!/usr/bin/env python3
"""Generate a VERTICAL test glTF with KHR_materials_displacement"""
import json
import base64
import struct
import numpy as np
from PIL import Image

def generate_displacement_texture(size=512, pattern="radial"):
    """Generate a radial displacement texture (easier to see)."""
    x = np.linspace(-1, 1, size)
    y = np.linspace(-1, 1, size)
    xx, yy = np.meshgrid(x, y)

    if pattern == "radial":
        # Radial pattern - bump in the center
        r = np.sqrt(xx**2 + yy**2)
        z = np.exp(-r**2 * 2)  # Gaussian bump
    elif pattern == "checkerboard":
        # Checkerboard pattern
        z = ((np.floor(xx * 4) + np.floor(yy * 4)) % 2)
    else:
        z = np.ones((size, size)) * 0.5

    img = Image.fromarray((z * 255).astype(np.uint8), mode='L')
    img.save(f"displacement_vertical_{size}.png")
    print(f"Created displacement_vertical_{size}.png")
    return f"displacement_vertical_{size}.png"

def create_vertical_plane_gltf(displacement_texture, factor=0.2):
    """Create a VERTICAL plane (easier to see from default camera)."""
    # Vertical plane in XY, facing +Z (towards camera)
    # Positioned at Z = -3 (in front of camera at origin)
    z_pos = -3.0

    positions = [
        -1.0, -1.0, z_pos,  # v0 (bottom-left)
         1.0, -1.0, z_pos,  # v1 (bottom-right)
         1.0,  1.0, z_pos,  # v2 (top-right)
        -1.0,  1.0, z_pos,  # v3 (top-left)
    ]
    normals = [0.0, 0.0, 1.0] * 4  # All pointing towards camera (+Z)
    uvs = [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
    indices = [0, 1, 2, 0, 2, 3]

    # Pack binary data
    pos_bytes = struct.pack(f'{len(positions)}f', *positions)
    norm_bytes = struct.pack(f'{len(normals)}f', *normals)
    uv_bytes = struct.pack(f'{len(uvs)}f', *uvs)
    idx_bytes = struct.pack(f'{len(indices)}H', *indices)

    buffer_data = pos_bytes + norm_bytes + uv_bytes + idx_bytes
    buffer_b64 = base64.b64encode(buffer_data).decode('ascii')

    gltf = {
        "asset": {"version": "2.0", "generator": "MatForge Vertical Test Generator"},
        "extensionsUsed": ["KHR_materials_displacement"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "VerticalDisplacedPlane"}],
        "meshes": [{
            "name": "VerticalPlane",
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
                "indices": 3,
                "material": 0
            }]
        }],
        "materials": [{
            "name": "VerticalDisplacedMaterial",
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],  # White
                "metallicFactor": 0.0,
                "roughnessFactor": 0.5
            },
            "extensions": {
                "KHR_materials_displacement": {
                    "displacementGeometryTexture": {"index": 0, "texCoord": 0},
                    "displacementGeometryFactor": factor,
                    "displacementGeometryOffset": 0.0
                }
            }
        }],
        "textures": [{"source": 0}],
        "images": [{"uri": displacement_texture, "mimeType": "image/png"}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
             "min": [-1, -1, z_pos], "max": [1, 1, z_pos]},
            {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"}
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 48},
            {"buffer": 0, "byteOffset": 48, "byteLength": 48},
            {"buffer": 0, "byteOffset": 96, "byteLength": 32},
            {"buffer": 0, "byteOffset": 128, "byteLength": 12}
        ],
        "buffers": [{
            "byteLength": len(buffer_data),
            "uri": f"data:application/octet-stream;base64,{buffer_b64}"
        }]
    }

    with open("displaced_plane_vertical.gltf", "w") as f:
        json.dump(gltf, f, indent=2)
    print("Created displaced_plane_vertical.gltf")

if __name__ == "__main__":
    texture = generate_displacement_texture(512, "radial")
    create_vertical_plane_gltf(texture, factor=0.2)
