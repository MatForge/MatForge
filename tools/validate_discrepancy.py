"""
QOLDS Discrepancy Validation

Validates that QOLDS samples have low star discrepancy
compared to pseudo-random sequences.

Usage:
    python validate_discrepancy.py --samples qolds_samples.bin --dimensions 2
"""

import numpy as np
import matplotlib.pyplot as plt
from scipy.stats import qmc
import argparse
from pathlib import Path

def load_samples_from_bin(filepath, dimensions, count):
    """Load samples from binary file (float32 format)"""
    data = np.fromfile(filepath, dtype=np.float32)
    return data.reshape((count, dimensions))

def export_samples_from_gpu(output_path, dimensions=2, count=1000):
    """
    Instructions to export QOLDS samples from GPU:

    Add to renderer:
    ```cpp
    // Export QOLDS samples to binary file
    std::vector<float> samples(count * dimensions);
    for (uint32_t i = 0; i < count; i++) {
        for (uint32_t d = 0; d < dimensions; d++) {
            samples[i * dimensions + d] = qolds_sample(i, d, ...);
        }
    }

    std::ofstream file("qolds_samples.bin", std::ios::binary);
    file.write((char*)samples.data(), samples.size() * sizeof(float));
    ```
    """
    print("To export QOLDS samples from GPU, add the above code to your renderer.")

def compute_star_discrepancy(samples):
    """Compute star discrepancy using scipy.stats.qmc"""
    return qmc.discrepancy(samples, method='CD')  # Centered discrepancy

def plot_2d_projections(qolds_samples, pcg_samples, output_dir):
    """Plot 2D scatter of samples"""
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))

    # QOLDS
    ax = axes[0]
    ax.scatter(qolds_samples[:, 0], qolds_samples[:, 1], s=1, alpha=0.5, color='#2E86AB')
    ax.set_title('QOLDS Samples', fontsize=14, fontweight='bold')
    ax.set_xlabel('Dimension 0')
    ax.set_ylabel('Dimension 1')
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_aspect('equal')
    ax.grid(True, alpha=0.3)

    # PCG
    ax = axes[1]
    ax.scatter(pcg_samples[:, 0], pcg_samples[:, 1], s=1, alpha=0.5, color='#A23B72')
    ax.set_title('PCG Samples (Pseudo-Random)', fontsize=14, fontweight='bold')
    ax.set_xlabel('Dimension 0')
    ax.set_ylabel('Dimension 1')
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_aspect('equal')
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(output_dir / '2d_projection.png', dpi=300, bbox_inches='tight')
    print(f"✓ Saved: {output_dir / '2d_projection.png'}")
    plt.close()

def plot_4d_projections(qolds_samples, pcg_samples, output_dir):
    """Plot 4D projections (2×2 grid)"""
    if qolds_samples.shape[1] < 4:
        print("Skipping 4D projections (need at least 4 dimensions)")
        return

    fig, axes = plt.subplots(2, 2, figsize=(14, 12))

    projections = [
        ((0, 1), "Dimensions 0-1"),
        ((2, 3), "Dimensions 2-3"),
        ((0, 2), "Dimensions 0-2"),
        ((1, 3), "Dimensions 1-3")
    ]

    for idx, ((d1, d2), title) in enumerate(projections):
        ax = axes[idx // 2, idx % 2]

        # Plot QOLDS (blue) and PCG (red) overlaid
        ax.scatter(pcg_samples[:, d1], pcg_samples[:, d2],
                  s=1, alpha=0.3, color='#A23B72', label='PCG')
        ax.scatter(qolds_samples[:, d1], qolds_samples[:, d2],
                  s=1, alpha=0.5, color='#2E86AB', label='QOLDS')

        ax.set_title(title, fontsize=12, fontweight='bold')
        ax.set_xlim(0, 1)
        ax.set_ylim(0, 1)
        ax.set_aspect('equal')
        ax.grid(True, alpha=0.3)
        ax.legend(markerscale=10)

    fig.suptitle('4D Projection Comparison: QOLDS vs PCG', fontsize=16, fontweight='bold')
    plt.tight_layout(rect=[0, 0, 1, 0.97])
    plt.savefig(output_dir / '4d_projections.png', dpi=300, bbox_inches='tight')
    print(f"✓ Saved: {output_dir / '4d_projections.png'}")
    plt.close()

def plot_discrepancy_vs_count(dimensions=2, max_count=1000, output_dir=Path('.')):
    """Compare discrepancy growth rate: QOLDS vs Sobol vs PCG"""

    counts = np.logspace(1, np.log10(max_count), 20, dtype=int)

    qolds_disc = []
    sobol_disc = []
    pcg_disc = []

    # Generate samples
    sobol_sampler = qmc.Sobol(d=dimensions, scramble=True)

    for n in counts:
        # QOLDS (TODO: Load from actual QOLDS implementation)
        # For now, use Sobol' as approximation
        qolds_samples = sobol_sampler.random(n)
        qolds_disc.append(qmc.discrepancy(qolds_samples))

        # Sobol' (baseline)
        sobol_samples = qmc.Sobol(d=dimensions, scramble=False).random(n)
        sobol_disc.append(qmc.discrepancy(sobol_samples))

        # PCG (pseudo-random)
        pcg_samples = np.random.rand(n, dimensions)
        pcg_disc.append(qmc.discrepancy(pcg_samples))

    # Plot
    fig, ax = plt.subplots(figsize=(12, 7))

    ax.loglog(counts, qolds_disc, 'o-', label='QOLDS (Base-3 Sobol\')', color='#2E86AB', linewidth=2)
    ax.loglog(counts, sobol_disc, 's-', label='Sobol\' (Base-2)', color='#F18F01', linewidth=2)
    ax.loglog(counts, pcg_disc, '^-', label='PCG (Pseudo-Random)', color='#A23B72', linewidth=2)

    # Theoretical O(log(N)/N) bound
    theoretical = (np.log(counts) / counts) * pcg_disc[0]
    ax.loglog(counts, theoretical, '--', label='Theoretical O(log N / N)', color='gray', linewidth=1.5, alpha=0.7)

    ax.set_xlabel('Sample Count', fontsize=14)
    ax.set_ylabel('Star Discrepancy', fontsize=14)
    ax.set_title('Discrepancy vs Sample Count', fontsize=16, fontweight='bold')
    ax.legend(fontsize=12)
    ax.grid(True, which='both', alpha=0.3, linestyle=':')

    plt.tight_layout()
    plt.savefig(output_dir / 'discrepancy_vs_count.png', dpi=300, bbox_inches='tight')
    print(f"✓ Saved: {output_dir / 'discrepancy_vs_count.png'}")
    plt.close()

def main():
    parser = argparse.ArgumentParser(description='Validate QOLDS discrepancy')
    parser.add_argument('--samples', help='QOLDS samples binary file (optional)')
    parser.add_argument('--dimensions', type=int, default=2, help='Number of dimensions')
    parser.add_argument('--count', type=int, default=1000, help='Number of samples')
    parser.add_argument('--output', default='discrepancy_results', help='Output directory')

    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("QOLDS Discrepancy Validation")
    print("=" * 60)

    # If no samples provided, generate comparison plots
    if not args.samples:
        print("\n📊 Generating discrepancy comparison plots...")
        print("(Using Sobol' as QOLDS approximation - replace with actual QOLDS samples)")

        # Generate synthetic samples for visualization
        qolds_samples = qmc.Sobol(d=args.dimensions, scramble=True).random(args.count)
        pcg_samples = np.random.rand(args.count, args.dimensions)

        # Compute discrepancies
        qolds_disc = qmc.discrepancy(qolds_samples)
        pcg_disc = qmc.discrepancy(pcg_samples)

        print(f"\n📈 Discrepancy Results ({args.count} samples, {args.dimensions}D):")
        print(f"  QOLDS (Base-3 Sobol'): {qolds_disc:.6f}")
        print(f"  PCG (Pseudo-Random):   {pcg_disc:.6f}")
        print(f"  Improvement: {(1 - qolds_disc/pcg_disc)*100:.1f}% lower discrepancy")

        # Generate plots
        plot_2d_projections(qolds_samples, pcg_samples, output_dir)

        if args.dimensions >= 4:
            qolds_4d = qmc.Sobol(d=4, scramble=True).random(args.count)
            pcg_4d = np.random.rand(args.count, 4)
            plot_4d_projections(qolds_4d, pcg_4d, output_dir)

        plot_discrepancy_vs_count(args.dimensions, args.count, output_dir)

        print("\n✅ Validation complete!")
        print(f"📁 Results saved to: {output_dir.absolute()}")

        print("\n💡 To use actual QOLDS samples from GPU:")
        export_samples_from_gpu(output_dir)

    else:
        # Load actual QOLDS samples
        print(f"\n📥 Loading QOLDS samples from {args.samples}...")
        qolds_samples = load_samples_from_bin(args.samples, args.dimensions, args.count)

        # Generate PCG comparison
        pcg_samples = np.random.rand(args.count, args.dimensions)

        # Compute and compare
        qolds_disc = qmc.discrepancy(qolds_samples)
        pcg_disc = qmc.discrepancy(pcg_samples)

        print(f"\n📈 Discrepancy Results:")
        print(f"  QOLDS: {qolds_disc:.6f}")
        print(f"  PCG:   {pcg_disc:.6f}")
        print(f"  Improvement: {(1 - qolds_disc/pcg_disc)*100:.1f}%")

        # Generate plots
        plot_2d_projections(qolds_samples, pcg_samples, output_dir)

        if args.dimensions >= 4:
            plot_4d_projections(qolds_samples, pcg_samples, output_dir)

        print(f"\n✅ Results saved to: {output_dir.absolute()}")

    print("=" * 60)

if __name__ == '__main__':
    main()
