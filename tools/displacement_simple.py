#!/usr/bin/env python3
"""Generate a SIMPLE test glTF - constant displacement (easiest to debug)"""
import json
import base64
import struct
import numpy as np
from PIL import Image

def generate_simple_displacement(size=128):
    """Generate a simple constant displacement texture."""
    # Constant value of 0.5 (middle gray)
    z = np.ones((size, size)) * 0.5

    img = Image.fromarray((z * 255).astype(np.uint8), mode='L')
    img.save(f"displacement_simple_{size}.png")
    print(f"Created displacement_simple_{size}.png (constant 0.5)")
    return f"displacement_simple_{size}.png"

def create_simple_plane_gltf(displacement_texture, factor=0.5):
    """Create a simple vertical plane with constant displacement."""
    # Large vertical plane facing camera
    z_pos = -5.0  # Further from camera

    positions = [
        -2.0, -2.0, z_pos,  # v0 (bottom-left) - LARGER
         2.0, -2.0, z_pos,  # v1 (bottom-right)
         2.0,  2.0, z_pos,  # v2 (top-right)
        -2.0,  2.0, z_pos,  # v3 (top-left)
    ]
    normals = [0.0, 0.0, 1.0] * 4  # All pointing towards camera
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
        "asset": {"version": "2.0", "generator": "MatForge Simple Test"},
        "extensionsUsed": ["KHR_materials_displacement"],
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "SimpleDisplacedPlane"}],
        "meshes": [{
            "name": "SimplePlane",
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
                "indices": 3,
                "material": 0
            }]
        }],
        "materials": [{
            "name": "SimpleDisplacedMaterial",
            "pbrMetallicRoughness": {
                "baseColorFactor": [0.0, 1.0, 0.0, 1.0],  # Bright green for visibility
                "metallicFactor": 0.0,
                "roughnessFactor": 0.8
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
             "min": [-2, -2, z_pos], "max": [2, 2, z_pos]},
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

    with open("displaced_plane_simple.gltf", "w") as f:
        json.dump(gltf, f, indent=2)
    print("Created displaced_plane_simple.gltf (4x4 plane at Z=-5, green)")

if __name__ == "__main__":
    texture = generate_simple_displacement(128)
    create_simple_plane_gltf(texture, factor=0.5)
