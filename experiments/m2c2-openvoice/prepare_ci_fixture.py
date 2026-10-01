"""Fetch the already pinned optional pack solely for real simulator regression.
No weights enter Git, IPA, or test artifacts. App still validates every file.
"""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

MANIFEST = {'format_version': 1, 'pack_id': 'openvoice-v2-coreml', 'source_repository': 'myshell-ai/OpenVoice', 'source_revision': '3a72f7931fce14857c34a15b2d83ffbcaa755e16', 'converter_repository': 'mlboydaisuke/OpenVoice-V2-CoreML', 'converter_revision': 'b0f10347769c88bb6df26e268d4b84bc7237fdeb', 'license': 'MIT', 'compute_units': 'cpuAndGPU', 'files': [{'path': 'OpenVoice_SpeakerEncoder.mlpackage/Manifest.json', 'bytes': 617, 'sha256': '68da0c2b9f407a7d9cb39c597807ff4e854bc5ae4976718182af4def2605970a'}, {'path': 'OpenVoice_SpeakerEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel', 'bytes': 25281, 'sha256': 'b2eadb91cb59157aa4d4958bc6becee86758faf273de240b2b7a4969971fe7e5'}, {'path': 'OpenVoice_SpeakerEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin', 'bytes': 1627840, 'sha256': '6b50c4ca00b72862f7cd974f9bef7d1dd36d2a86adc0b6b626116fb26b5cc6de'}, {'path': 'OpenVoice_VoiceConverter.mlpackage/Manifest.json', 'bytes': 617, 'sha256': '66aad1bb6ba0d360556db96babf2a2e42124a07612a74a351812d10f6ad9eec0'}, {'path': 'OpenVoice_VoiceConverter.mlpackage/Data/com.apple.CoreML/model.mlmodel', 'bytes': 482492, 'sha256': 'c7ca229e9fe7f8508884512f6c1100c1fa38fd15bb5e7b9b2641246733cf8fc0'}, {'path': 'OpenVoice_VoiceConverter.mlpackage/Data/com.apple.CoreML/weights/weight.bin', 'bytes': 63887808, 'sha256': 'bc5c2c0952a4146a74ae7c4dce9ccda8c294af8b41ee4dbadc7d47077d8104ea'}]}

def prepare(destination):
    destination.mkdir(parents=True, exist_ok=True)
    for item in MANIFEST['files']:
        path = destination / item['path']
        path.parent.mkdir(parents=True, exist_ok=True)
        url = 'https://huggingface.co/' + MANIFEST['converter_repository'] + '/resolve/' + MANIFEST['converter_revision'] + '/' + item['path']
        with urllib.request.urlopen(url, timeout=120) as response, path.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        data = path.read_bytes()
        if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Pinned fixture verification failed: ' + item['path'])
    (destination / 'manifest.json').write_text(json.dumps(MANIFEST, indent=2), encoding='utf-8')
    print('Verified existing pinned OpenVoice simulator fixture')

if __name__ == '__main__':
    prepare(Path(sys.argv[1]))
