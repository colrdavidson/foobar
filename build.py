#!/usr/bin/env python3

import glob
import os
import re
import subprocess
import random
import shutil
import string
import sys
import time

RELEASE = len(sys.argv) > 1 and sys.argv[1] == 'release'
EXTRARELEASE = len(sys.argv) > 1 and sys.argv[1] == 'extrarelease'

odin = 'odin'
golang = 'go'
program_name = 'spall'

[os.remove(f) for f in glob.iglob('build/dist/*', recursive=True)]
for ext in ['*.o', '*.wasm', '*.wat']:
    [os.remove(f) for f in glob.iglob('build/**/' + ext, recursive=True)]

os.makedirs('build', exist_ok=True)

build_str = []
if RELEASE:
    build_str = ['-o:speed']
elif EXTRARELEASE:
    build_str = ['-o:speed']
else:
    build_str = ['-debug']

wasm_out = f"build/{program_name}.wasm"

start_time = time.time()
print('Compiling...')
subprocess.run([
    odin,
    'build', 'src',
    '-collection:formats=formats',
    '-target:js_wasm32',
    f"-out:{wasm_out}",
    *build_str,
], check=True)
os.chdir("srvr")
subprocess.run([
    golang,
    'build',
    '-o',
    '../build/server',
], check=True)
os.chdir("..")
print("Compiled in {:.1f} seconds".format(time.time() - start_time))

if EXTRARELEASE:
    # Patch memcpy and memmove
    start_time = time.time()
    print('Patching WASM...')
    subprocess.run([
        'wasm2wat',
        '-o', f"build/{program_name}.wat",
        wasm_out,
    ], check=True)
    memcpy = """(\\1
        local.get 0
        local.get 1
        local.get 2
        memory.copy
        local.get 0)"""
    memset = """(\\1
        local.get 0
        local.get 1
        local.get 2
        memory.fill
        local.get 0)"""
    with open(f"build/{program_name}.wat", 'r') as infile, open(f"build/{program_name}_patched.wat", 'w') as outfile:
        wat = infile.read()
        wat = re.sub(r'\((func \$memcpy.*?\(result i32\)).*?local.get 0(.*?return)?\)', memcpy, wat, flags=re.DOTALL)
        wat = re.sub(r'\((func \$memmove.*?\(result i32\)).*?local.get 0(.*?return)?\)', memcpy, wat, flags=re.DOTALL)
        wat = re.sub(r'\((func \$memset.*?\(result i32\)).*?local.get 0(.*?return)?\)', memset, wat, flags=re.DOTALL)
        outfile.write(wat)
    subprocess.run([
        'wat2wasm',
        '-o', f"build/{program_name}_patched.wasm",
        f"build/{program_name}_patched.wat",
    ], check=True)
    wasm_out = f"build/{program_name}_patched.wasm"
    print("Patched in {:.1f} seconds".format(time.time() - start_time))

#
# Output the dist folder for upload
#

print('Building dist folder...')
os.makedirs('build/dist', exist_ok=True)

buildId = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8)) # so beautiful. so pythonic.

root = 'src/index.html'
rootContents = open(root).read()

def addId(filename, id):
    parts = filename.split('.')
    parts.insert(-1, buildId)
    return '.'.join(parts)

def patchFile(filename, embed_name):
    global rootContents

    basename = os.path.basename(filename)
    embed_base = os.path.basename(embed_name)
    new_filename = addId(embed_base, buildId)
    shutil.copy(filename, 'build/dist/{}'.format(new_filename))

    rootContents = rootContents.replace(embed_base, new_filename)


patchFile('src/runtime.js', 'src/runtime.js')
patchFile(wasm_out, f"src/{program_name}.wasm")

with open('build/dist/index.html', 'w') as f:
    f.write(rootContents)

print('Done!')
