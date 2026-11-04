import { cpSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
cpSync('node_modules/@excalidraw/excalidraw/dist/prod/fonts', 'dist/fonts', { recursive: true });
mkdirSync('../assets', { recursive: true });
// Recreate the archive: removed assets must not linger across builds.
execFileSync('python3', ['-c', `
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
with ZipFile('../assets/whiteboard.zip', 'w', ZIP_DEFLATED) as archive:
    for path in sorted(Path('dist').rglob('*')):
        if path.is_file():
            archive.write(path, path.relative_to('dist'))
`]);
