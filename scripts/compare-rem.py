#!/usr/bin/env python3
"""Build a pinned rem database-method reference and compare isolated synthetic text.

Downloads MIT upstream sources into ignored .local; retains the upstream license.
Does not launch rem, access its user data, or capture the desktop. See report scope.
"""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REVISION = 'f4f68049a064557bddeb93753f82aa41af776b98'
DB_SHA256 = 'a859bf79fb1dc79a62edf80c3b8a2bfcb84cfd0d1c53eeaab052c0d29e2d18cb'

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, default=1000)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--workspace', type=pathlib.Path, help='Reuse a marked benchmark build directory')
    parser.add_argument('--prepare-only', action='store_true', help='Stage sources without compiling/running')
    args = parser.parse_args()
    if not 32 <= args.count <= 100000:
        parser.error('count must be 32–100000')
    source = ROOT/'.local/competitors/rem'
    source.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        run('git', 'clone', '--filter=blob:none', 'https://github.com/jasonjmcghee/rem', source)
        run('git', '-C', source, 'checkout', '--detach', REVISION)
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != REVISION or subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip():
        raise RuntimeError('Reference checkout must be clean at the pinned revision; it will not be reset automatically')
    run('git', '-C', source, 'submodule', 'update', '--init', '--depth', '1')
    original = (source/'rem/DB.swift').read_bytes()
    if hashlib.sha256(original).hexdigest() != DB_SHA256:
        raise RuntimeError('Unexpected upstream database source')
    workspace = args.workspace.resolve() if args.workspace else pathlib.Path(tempfile.mkdtemp(prefix='rem-component-', dir=source.parent))
    marker = workspace/'comparison-workspace.json'
    identity = {'kind':'OSwind rem component comparison v1','rem_revision':REVISION,'oswind_root':str(ROOT)}
    if workspace.exists() and any(workspace.iterdir()):
        if not marker.exists() or json.loads(marker.read_text()) != identity:
            raise RuntimeError('Refusing to reuse an unmarked/different comparison directory')
    workspace.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps(identity, indent=2))
    target = workspace/'Sources/RemCompare'
    target.mkdir(parents=True, exist_ok=True)
    (workspace/'REM-LICENSE.txt').write_bytes((source/'LICENSE').read_bytes())
    # A CLI has no application bundle identifier. No source SQL is changed.
    adapted = original.decode().replace('Bundle.main.bundleIdentifier!', 'Bundle.main.bundleIdentifier ?? "org.oswind.benchmark.rem"')
    (target/'DB.swift').write_text(adapted)
    shutil.copy2(ROOT/'scripts/comparisons/RemCompare.swift', target/'Compare.swift')
    (target/'RemFileManager.swift').write_text('''import Foundation
final class RemFileManager {
    static let shared = RemFileManager()
    func getSaveDir() -> URL? { URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("rem") }
}
''')
    # json string escaping is correct Swift string syntax for these file paths.
    (workspace/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"RemComparison",platforms:[.macOS(.v14)],dependencies:[
.package(name:"OSwind",path:%s),.package(name:"RemSQLite",path:%s)
],targets:[.executableTarget(name:"RemCompare",dependencies:[.product(name:"OSwindCore",package:"OSwind"),.product(name:"SQLite",package:"RemSQLite")])],swiftLanguageModes:[.v5])
''' % (json.dumps(str(ROOT)), json.dumps(str(source/'SQLite.swift'))))
    shutil.copy2(ROOT/'Package.resolved', workspace/'Package.resolved')
    print(f'Staged pinned comparison at {workspace}', flush=True)
    if args.prepare_only:
        return
    run('swift', 'build', '-c', 'release', '--package-path', workspace)
    binary_dir = subprocess.check_output(['swift','build','-c','release','--package-path',str(workspace),'--show-bin-path'],text=True).strip()
    archive = pathlib.Path(tempfile.mkdtemp(prefix=f'archive-{args.count}-', dir=workspace))
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    tree = hashlib.sha256()
    for entry in sorted([*ROOT.joinpath('Sources').rglob('*.swift'),ROOT/'Package.swift',ROOT/'Package.resolved']):
        tree.update(str(entry.relative_to(ROOT)).encode()+b'\0'+entry.read_bytes())
    environment['OSWIND_COMPARISON_SOURCE_SHA256'] = tree.hexdigest()
    environment['OSWIND_COMPARISON_REVISION'] = subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()
    run(pathlib.Path(binary_dir)/'RemCompare', args.count, archive, ROOT/'benchmarks/fixtures/desktop-retrieval-v1.json', ROOT/'benchmarks/fixtures/lexical-comparison-v1.json', output, DB_SHA256, env=environment)
    print('Retained isolated synthetic archive and build:', workspace)

if __name__ == '__main__':
    main()
