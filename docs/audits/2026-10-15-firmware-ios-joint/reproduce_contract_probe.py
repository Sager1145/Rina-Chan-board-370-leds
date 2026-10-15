from pathlib import Path
import subprocess, tempfile, shutil
ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="rina-joint-contract-") as directory:
    scratch = Path(directory)
    main = scratch / "main.swift"
    shutil.copyfile(HERE / "contract_probe.swift", main)
    sources = sorted((ROOT / "ios/Packages/RinaCore/Sources/RinaCore").glob("*.swift"))
    binary = scratch / "contract-probe"
    subprocess.run(["swiftc", "-swift-version", "6", *map(str, sources), str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(ROOT)], check=True)
