#!/usr/bin/env python3
"""Quick test to convert a model and verify it works"""

import subprocess
import sys
import os

# Install requirements
print("📦 Installing required packages...")
subprocess.check_call([sys.executable, "-m", "pip", "install", 
                      "torch", "transformers", "coremltools", "numpy", "sentencepiece"])

# Now run the conversion
print("\n🔄 Converting model...")
script_path = "../EmbedKit/Scripts/convert_to_coreml.py"
subprocess.check_call([sys.executable, script_path, 
                      "sentence-transformers/all-MiniLM-L6-v2",
                      "--output", "../EmbedKit/Models",
                      "--test"])

print("\n✅ Done! Check ../EmbedKit/Models for the converted model.")