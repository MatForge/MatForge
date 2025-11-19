"""
Automated Convergence Test Runner for MatForge

Automates the full convergence testing workflow:
1. Render reference image (high quality)
2. Run QOLDS test (capture at 1, 2, 4, 8, 16, 32, 64 spp)
3. Run PCG test (same sample counts)
4. Generate plots and analysis

Usage:
    python run_convergence_test.py --config convergence_test.json
"""

import subprocess
import json
import time
from pathlib import Path
import argparse

class ConvergenceTestRunner:
    def __init__(self, config_path):
        with open(config_path) as f:
            self.config = json.load(f)

        self.exe_path = Path(self.config['executable'])
        self.scene = self.config['scene']
        self.output_dir = Path(self.config['output_dir'])
        self.output_dir.mkdir(parents=True, exist_ok=True)

        self.sample_counts = self.config.get('sample_counts', [1, 2, 4, 8, 16, 32, 64])
        self.resolution = self.config.get('resolution', [1920, 1080])
        self.max_depth = self.config.get('max_depth', 5)

    def run_render(self, sampler, samples, output_path, headless=True):
        """Run MatForge renderer with specific parameters"""

        cmd = [
            str(self.exe_path),
            '--scenefile', self.scene,
            '--samples', str(samples),
            '--max-depth', str(self.max_depth),
            '--size', str(self.resolution[0]), str(self.resolution[1]),
            '--output', str(output_path),
            '--sampler', sampler
        ]

        if headless:
            cmd.append('--headless')

        print(f"  Running: {' '.join(cmd)}")
        start_time = time.time()

        result = subprocess.run(cmd, capture_output=True, text=True)

        elapsed = time.time() - start_time

        if result.returncode != 0:
            print(f"  ❌ Error: {result.stderr}")
            return None

        print(f"  ✓ Completed in {elapsed:.2f}s")
        return elapsed

    def render_reference(self):
        """Render high-quality reference image"""
        print("\n🎨 Rendering reference image (1024 spp)...")

        ref_path = self.output_dir / 'reference.exr'
        self.run_render('qolds', 1024, ref_path, headless=True)

        return ref_path

    def run_convergence_test(self, sampler_name):
        """Run convergence test for a specific sampler"""
        print(f"\n🔬 Running convergence test: {sampler_name.upper()}")

        results = []

        for spp in self.sample_counts:
            print(f"\n  Sample count: {spp}")

            output_path = self.output_dir / f'{sampler_name}_{spp}spp.exr'
            elapsed = self.run_render(sampler_name, spp, output_path)

            if elapsed:
                results.append({
                    'sampleCount': spp,
                    'timeMs': elapsed * 1000,
                    'imagePath': str(output_path)
                })

        # Export CSV
        csv_path = self.output_dir / f'{sampler_name}_convergence.csv'
        with open(csv_path, 'w') as f:
            f.write("SampleCount,MSE,PSNR,TimeMs,Sampler\n")
            # Note: MSE/PSNR computed by C++ analyzer or post-processing
            for r in results:
                f.write(f"{r['sampleCount']},0,0,{r['timeMs']},{sampler_name}\n")

        print(f"\n✓ {sampler_name.upper()} test complete: {csv_path}")
        return csv_path

    def generate_plots(self, qolds_csv, pcg_csv):
        """Generate convergence plots"""
        print("\n📊 Generating plots...")

        plot_dir = self.output_dir / 'plots'
        plot_dir.mkdir(exist_ok=True)

        cmd = [
            'python', 'tools/plot_convergence.py',
            '--qolds', str(qolds_csv),
            '--pcg', str(pcg_csv),
            '--output', str(plot_dir)
        ]

        subprocess.run(cmd, check=True)
        print(f"✓ Plots saved to: {plot_dir}")

    def run_full_test(self):
        """Run complete convergence analysis"""
        print("=" * 70)
        print("MatForge Convergence Test Runner")
        print("=" * 70)
        print(f"Scene: {self.scene}")
        print(f"Resolution: {self.resolution[0]}×{self.resolution[1]}")
        print(f"Sample counts: {self.sample_counts}")
        print(f"Output: {self.output_dir}")
        print("=" * 70)

        # Step 1: Render reference
        ref_path = self.render_reference()

        # Step 2: QOLDS test
        qolds_csv = self.run_convergence_test('qolds')

        # Step 3: PCG test
        pcg_csv = self.run_convergence_test('pcg')

        # Step 4: Generate plots
        self.generate_plots(qolds_csv, pcg_csv)

        print("\n" + "=" * 70)
        print("✅ Convergence test complete!")
        print(f"📁 Results: {self.output_dir}")
        print("=" * 70)

def main():
    parser = argparse.ArgumentParser(description='Run convergence test')
    parser.add_argument('--config', default='convergence_test.json',
                       help='Test configuration file')

    args = parser.parse_args()

    runner = ConvergenceTestRunner(args.config)
    runner.run_full_test()

if __name__ == '__main__':
    main()
