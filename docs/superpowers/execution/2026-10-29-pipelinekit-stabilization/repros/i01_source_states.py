#!/usr/bin/env python3
"""Retain exact consumer iteration sources, identifying reconstructed intermediate state."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
root=Path(__file__).resolve().parents[5]
execution=root/'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization'
reports=execution/'reports'
BASE='a6979832b0665aaf6b6769e9d16fa0cd044442c6'
IMPLEMENTATION='6bd49c4fe1ee0aac9f174871bc691c7f96b5b50c'
def committed(path, revision=IMPLEMENTATION):
    return subprocess.check_output(['git','show',revision+':'+path],cwd=root,text=True)
def sha(text):return hashlib.sha256(text.encode()).hexdigest()
def apply_file(diff,path):
    original=committed(path, BASE).splitlines(keepends=True)
    marker='diff --git a/'+path+' b/'+path+'\n'
    segment=(diff.split(marker,1)[1].split('\ndiff --git ',1)[0].rstrip('\n')+'\n').splitlines(keepends=True)
    result=[];position=0;active=False
    for line in segment:
        match=re.match(r'@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@',line)
        if match:
            start=int(match[1])-1;result.extend(original[position:start]);position=start;active=True;continue
        if not active:continue
        if line.startswith('\\'):continue
        if line.startswith((' ','-')):
            assert original[position] == line[1:], (path,position,line,original[position]);position+=1
        if line.startswith((' ','+')):result.append(line[1:])
    result.extend(original[position:]);return ''.join(result)
diff=(reports/'I01-runtime-source.diff').read_text()
files=['docs/migrations/first-stabilization-batch.md','README.md','docs/guides/security-best-practices.md','docs/guides/resilience-patterns.md']
texts={f:apply_file(diff,f) for f in files}
committed_compiled=committed(str((execution/'Consumer/Sources/Consumer/CompiledExamples.swift').relative_to(root)))
compiled=committed_compiled.split('// docs/migrations/',1)[0]
pattern=re.compile(r'```swift\n(.*?)```',re.S)
for f in files:
    old=subprocess.run(['git','show','a93a713:'+f],cwd=root,text=True,capture_output=True)
    oldfences=pattern.findall(old.stdout)
    for number,snippet in enumerate(pattern.findall(texts[f]),1):
        if f != files[0] and snippet in oldfences:continue
        generated=snippet
        if f != files[0]:
            generated=re.sub(r'^import [^\n]+\n','',snippet,flags=re.M)
            support='    let pipeline = DynamicPipeline()\n' if f=='README.md' and number==19 else ''
            name=re.sub('[^a-zA-Z0-9]','_',f)
            generated=f'@MainActor func compiled_{name}_{number}() async throws {{\n'+support+generated+'\n}\n'
        compiled+='// '+f+', Swift fence '+str(number)+'\n'+generated+'\n'
main_path=str((execution/'Consumer/Sources/Consumer/main.swift').relative_to(root))
compiled_path=str((execution/'Consumer/Sources/Consumer/CompiledExamples.swift').relative_to(root))
state=json.loads((reports/'I01-runtime-source.json').read_text())
assert sha(compiled)==state['files'][compiled_path]
main=committed(main_path);assert sha(main)==state['files'][main_path]
final=json.loads((reports/'I01-final-source.json').read_text())
assert sha(main)==final['files'][main_path]
assert sha(committed_compiled)==final['files'][compiled_path]
main003=main.replace('AnyStandardPipeline(handler: handler, options: .init(maxConcurrency: 10, maxOutstanding: nil))','AnyStandardPipeline(handler: handler)').replace('maxQueueSize: 16, queueTimeout: nil, rejectionPolicy: .queue, emitMetrics: false','maxQueueSize: 16, queueTimeout: nil, emitMetrics: false')
compiled003=compiled.replace('maxConcurrency: 100, maxQueueSize: 100, queueTimeout: 5, rejectionPolicy: .queue','maxConcurrency: 100, maxQueueSize: 100, queueTimeout: 5')
main001=apply_file((reports/'I01-001-source.diff').read_text(),main_path)
compiled001=compiled003.replace('_ = encryptor // Retain this actor in the application service that encrypts commands.\n','')
initial=json.loads((reports/'I01-001-source.json').read_text())
assert sha(main001)==initial['files'][main_path]
assert sha(compiled001)==initial['files'][compiled_path]
out=reports/'I01-source-states';out.mkdir(exist_ok=True)
records=[]
for name,main_text,example_text,runs,note in [
 ('001',main001,compiled001,['001'],'Reconstructed from contemporaneous I01-001 diff; both original captured SHA-256 values verified.'),
 ('003',main003,compiled003,['003','004','005','006','007','008'],'Intermediate snapshot reconstructed by reversing the two exact subsequent fixture corrections (supported erased options and queue policy); no contemporaneous full snapshot claimed.'),
 ('013',main,compiled,['013','014','015','016','017','018','019','030','031','032','033','034','035','036','037','038','039'],'Matches captured I01-runtime-source.json hashes; all final consumer runtime modes used this source.'),
 ('044',main,committed_compiled,['044','045'],'Final documentation-only authorization example refinement; runtime main unchanged.')]:
    (out/f'{name}-main.swift').write_text(main_text);(out/f'{name}-CompiledExamples.swift').write_text(example_text)
    records.append(dict(state=name,run_numbers=runs,main_sha256=sha(main_text),compiled_examples_sha256=sha(example_text),provenance=note))
(reports/'I01-source-states.json').write_text(json.dumps({'i01_base':BASE,'implementation_source':IMPLEMENTATION,'states':records,'root_source':'All root source/tests/manifests unchanged from I01 base; I01-final-source.json records final hashes.'},indent=2)+'\n')
print('All retained contemporaneous consumer source hashes verified; intermediate003 reconstruction explicitly labelled.')
