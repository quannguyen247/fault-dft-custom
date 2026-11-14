"""Package the independent Tcl shell and its runtime resources."""
from pathlib import Path
from setuptools import setup

HERE = Path(__file__).resolve().parent

setup(
    name="faultplus-shell",
    version="0.1.0",
    description="Cadence-style Tcl interface for the Fault DFT backend",
    long_description=(HERE / "README.md").read_text(encoding="utf-8"),
    long_description_content_type="text/markdown",
    license="Apache-2.0",
    license_files=["LICENSE"],
    python_requires=">=3.9",
    packages=["faultplus_runtime", "faultplus_runtime.bin", "faultplus_runtime.src"],
    package_dir={"faultplus_runtime": "."},
    package_data={"faultplus_runtime.bin": ["faultplus"],
                  "faultplus_runtime.src": ["*.tcl", "*.v"]},
    entry_points={"console_scripts": ["faultplus = faultplus_runtime.launcher:main"]},
)
