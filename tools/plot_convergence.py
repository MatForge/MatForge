#!/usr/bin/env python3
"""
Convergence Analysis Plot Generator for MatForge QOLDS Testing

This script takes two CSV files (typically QOLDS and PCG test results) and generates
comparison graphs for analyzing sampling convergence performance.

Usage:
    python plot_convergence.py <csv_file_1> <csv_file_2> [--output <output_file>]

Example:
    python plot_convergence.py ../test/qolds_test_20251121_192936.csv ../test/pcg_test_20251121_193006.csv
"""

import argparse
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path
from datetime import datetime


def load_csv(filepath: str) -> pd.DataFrame:
    """Load a convergence test CSV file."""
    df = pd.read_csv(filepath)
    return df


def compute_improvement(df1: pd.DataFrame, df2: pd.DataFrame) -> pd.DataFrame:
    """Compute improvement metrics between two datasets."""
    # Merge on SampleCount
    merged = pd.merge(df1, df2, on='SampleCount', suffixes=('_1', '_2'))

    # Calculate improvements
    merged['MSE_Improvement_Pct'] = (merged['MSE_2'] - merged['MSE_1']) / merged['MSE_2'] * 100
    merged['PSNR_Improvement_dB'] = merged['PSNR_1'] - merged['PSNR_2']

    return merged


def plot_convergence(csv1: str, csv2: str, output: str = None):
    """Generate convergence comparison plots."""
    # Load data
    df1 = load_csv(csv1)
    df2 = load_csv(csv2)

    # Get sampler names
    sampler1 = df1['Sampler'].iloc[0] if 'Sampler' in df1.columns else Path(csv1).stem
    sampler2 = df2['Sampler'].iloc[0] if 'Sampler' in df2.columns else Path(csv2).stem

    # Create figure with subplots
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle(f'Convergence Analysis: {sampler1} vs {sampler2}', fontsize=14, fontweight='bold')

    # Color scheme
    color1 = '#2ecc71'  # Green for QOLDS
    color2 = '#3498db'  # Blue for PCG

    # Swap colors if needed (QOLDS should be green)
    if 'PCG' in sampler1.upper():
        color1, color2 = color2, color1

    # === Plot 1: PSNR vs Sample Count ===
    ax1 = axes[0, 0]
    ax1.semilogx(df1['SampleCount'], df1['PSNR'], 'o-', color=color1,
                 linewidth=2, markersize=8, label=sampler1)
    ax1.semilogx(df2['SampleCount'], df2['PSNR'], 's--', color=color2,
                 linewidth=2, markersize=8, label=sampler2)
    ax1.set_xlabel('Sample Count', fontsize=11)
    ax1.set_ylabel('PSNR (dB)', fontsize=11)
    ax1.set_title('Image Quality vs Sample Count', fontsize=12)
    ax1.legend(loc='lower right')
    ax1.grid(True, alpha=0.3)
    ax1.set_xticks(df1['SampleCount'])
    ax1.set_xticklabels(df1['SampleCount'].astype(int))

    # === Plot 2: MSE vs Sample Count (log-log) ===
    ax2 = axes[0, 1]
    ax2.loglog(df1['SampleCount'], df1['MSE'], 'o-', color=color1,
               linewidth=2, markersize=8, label=sampler1)
    ax2.loglog(df2['SampleCount'], df2['MSE'], 's--', color=color2,
               linewidth=2, markersize=8, label=sampler2)
    ax2.set_xlabel('Sample Count', fontsize=11)
    ax2.set_ylabel('MSE (log scale)', fontsize=11)
    ax2.set_title('Error vs Sample Count', fontsize=12)
    ax2.legend(loc='upper right')
    ax2.grid(True, alpha=0.3, which='both')
    ax2.set_xticks(df1['SampleCount'])
    ax2.set_xticklabels(df1['SampleCount'].astype(int))

    # === Plot 3: PSNR Improvement ===
    ax3 = axes[1, 0]
    improvement = compute_improvement(df1, df2)

    colors = ['#27ae60' if x > 0 else '#e74c3c' for x in improvement['PSNR_Improvement_dB']]
    bars = ax3.bar(range(len(improvement)), improvement['PSNR_Improvement_dB'], color=colors, alpha=0.8)
    ax3.axhline(y=0, color='black', linestyle='-', linewidth=0.5)
    ax3.set_xlabel('Sample Count', fontsize=11)
    ax3.set_ylabel(f'PSNR Improvement (dB)\n({sampler1} - {sampler2})', fontsize=11)
    ax3.set_title('Quality Improvement per Sample Count', fontsize=12)
    ax3.set_xticks(range(len(improvement)))
    ax3.set_xticklabels(improvement['SampleCount'].astype(int))
    ax3.grid(True, alpha=0.3, axis='y')

    # Add value labels on bars
    for bar, val in zip(bars, improvement['PSNR_Improvement_dB']):
        height = bar.get_height()
        ax3.annotate(f'{val:.2f}',
                     xy=(bar.get_x() + bar.get_width() / 2, height),
                     xytext=(0, 3 if height >= 0 else -10),
                     textcoords="offset points",
                     ha='center', va='bottom' if height >= 0 else 'top',
                     fontsize=9)

    # === Plot 4: MSE Improvement Percentage ===
    ax4 = axes[1, 1]
    colors = ['#27ae60' if x > 0 else '#e74c3c' for x in improvement['MSE_Improvement_Pct']]
    bars = ax4.bar(range(len(improvement)), improvement['MSE_Improvement_Pct'], color=colors, alpha=0.8)
    ax4.axhline(y=0, color='black', linestyle='-', linewidth=0.5)
    ax4.set_xlabel('Sample Count', fontsize=11)
    ax4.set_ylabel(f'MSE Reduction (%)\n({sampler1} vs {sampler2})', fontsize=11)
    ax4.set_title('Error Reduction per Sample Count', fontsize=12)
    ax4.set_xticks(range(len(improvement)))
    ax4.set_xticklabels(improvement['SampleCount'].astype(int))
    ax4.grid(True, alpha=0.3, axis='y')

    # Add value labels on bars
    for bar, val in zip(bars, improvement['MSE_Improvement_Pct']):
        height = bar.get_height()
        ax4.annotate(f'{val:.1f}%',
                     xy=(bar.get_x() + bar.get_width() / 2, height),
                     xytext=(0, 3 if height >= 0 else -10),
                     textcoords="offset points",
                     ha='center', va='bottom' if height >= 0 else 'top',
                     fontsize=9)

    # Adjust layout
    plt.tight_layout()

    # Save or show
    if output:
        output_path = Path(output)
    else:
        # Generate output filename based on input files
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        output_path = Path(csv1).parent / f'convergence_comparison_{timestamp}.png'

    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f"Plot saved to: {output_path}")

    # Close the figure to free memory (skip interactive window)
    plt.close(fig)

    # Print summary statistics
    print("\n" + "="*60)
    print("CONVERGENCE ANALYSIS SUMMARY")
    print("="*60)
    print(f"\nComparing: {sampler1} vs {sampler2}")
    print("-"*60)

    avg_psnr_improvement = improvement['PSNR_Improvement_dB'].mean()
    avg_mse_improvement = improvement['MSE_Improvement_Pct'].mean()

    print(f"\nAverage PSNR Improvement: {avg_psnr_improvement:+.3f} dB")
    print(f"Average MSE Reduction:    {avg_mse_improvement:+.2f}%")

    print("\nPer Sample Count:")
    print("-"*60)
    print(f"{'Samples':>8} | {'PSNR Gain (dB)':>14} | {'MSE Reduction (%)':>17}")
    print("-"*60)
    for _, row in improvement.iterrows():
        print(f"{int(row['SampleCount']):>8} | {row['PSNR_Improvement_dB']:>+14.3f} | {row['MSE_Improvement_Pct']:>+17.2f}")
    print("-"*60)

    # Final verdict
    print("\n" + "="*60)
    if avg_psnr_improvement > 0:
        print(f"VERDICT: {sampler1} converges faster than {sampler2}")
        print(f"         {sampler1} achieves equivalent quality with ~{100/(100-avg_mse_improvement)*100 - 100:.1f}% fewer samples")
    else:
        print(f"VERDICT: {sampler2} converges faster than {sampler1}")
    print("="*60)


def main():
    parser = argparse.ArgumentParser(
        description='Generate convergence comparison plots from CSV test results.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python plot_convergence.py qolds_test.csv pcg_test.csv
    python plot_convergence.py ../test/qolds_test.csv ../test/pcg_test.csv --output comparison.png
        """
    )
    parser.add_argument('csv1', help='First CSV file (e.g., QOLDS test results)')
    parser.add_argument('csv2', help='Second CSV file (e.g., PCG test results)')
    parser.add_argument('--output', '-o', help='Output image file (default: auto-generated)')

    args = parser.parse_args()

    # Validate input files
    if not Path(args.csv1).exists():
        print(f"Error: File not found: {args.csv1}")
        return 1
    if not Path(args.csv2).exists():
        print(f"Error: File not found: {args.csv2}")
        return 1

    plot_convergence(args.csv1, args.csv2, args.output)
    return 0


if __name__ == '__main__':
    exit(main())
