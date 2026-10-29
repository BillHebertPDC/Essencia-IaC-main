#!/usr/bin/env python3
"""Rebuild the embedded application payload in infra/03-cluster.yml.

O template 03-cluster.yml tem uma linha `AppPayload: <base64>` dentro do
Fn::Sub do user data. Essa linha contem o payload que o manager 1 usa para
publicar a aplicacao automaticamente depois que o Swarm fica pronto:

  swarm/app-bootstrap/deploy-app.sh (com o Compose injetado no marcador
  #__COMPOSE__) -> compressao LZMA (xz) -> base64 em uma unica linha

O user data decodifica com base64 + python3 (garantido pelo bootstrap) e
executa o script; sem dependencia de xz/tar na imagem.

Depois de editar o Compose ou o deploy-app.sh, rode a partir da pasta infra:

  python scripts\\build-app-payload.py
  python scripts\\build-app-payload.py --stats   # so mede, nao grava

O user data final nao pode passar de 16384 bytes apos Base64 (limite EC2);
o script imprime o tamanho estimado e falha se estourar.
"""
import argparse
import base64
import lzma
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
INFRA = os.path.dirname(HERE)
COMPOSE = os.path.join(INFRA, "swarm", "studio-essencia-stack-placement.yml")
DEPLOY_SCRIPT = os.path.join(INFRA, "swarm", "app-bootstrap", "deploy-app.sh")
TEMPLATE = os.path.join(INFRA, "03-cluster.yml")

PAYLOAD_LIMIT_RAW = 12288  # 16 KiB Base64 -> ~12.2 KiB de texto puro
TOKENS = {
    "Manager1PrivateIp": "10.20.11.10",
    "Manager2PrivateIp": "10.20.12.10",
    "Manager3PrivateIp": "10.20.13.10",
    "PublicHost": "203.0.113.10",
}


def read_lf(path):
    with open(path, "rb") as fh:
        return fh.read().replace(b"\r\n", b"\n")


def strip_noise(data, keep_shebang=False):
    """Remove linhas de comentario e linhas em branco (inocuo em YAML/bash;
    base64 do payload nao contem '#' nem linhas vazias)."""
    out = []
    lines = data.split(b"\n")
    for idx, line in enumerate(lines):
        if keep_shebang and idx == 0 and line.startswith(b"#!"):
            out.append(line.rstrip())
            continue
        if not line.strip():
            continue
        if line.lstrip().startswith(b"#"):
            continue
        out.append(line.rstrip())
    return b"\n".join(out) + b"\n"


def build_payload():
    script = read_lf(DEPLOY_SCRIPT)
    if b"#__COMPOSE__" not in script:
        raise SystemExit("marcador #__COMPOSE__ ausente em deploy-app.sh")
    # 1) monta o script completo com o Compose injetado (sem comentarios)
    script = script.replace(b"#__COMPOSE__\n", strip_noise(read_lf(COMPOSE)))
    # 2) remove comentarios/branco do wrapper, preservando o shebang
    script = strip_noise(script, keep_shebang=True)
    blob = lzma.compress(script, format=lzma.FORMAT_ALONE, preset=9)
    return base64.b64encode(blob).decode("ascii"), len(script), len(blob)


def template_script_region(lines):
    start = None
    end = None
    for i, line in enumerate(lines):
        if start is None and "Fn::Base64: !Sub" in line:
            start = i + 2
            continue
        if start is not None and re.match(r"^ {12}- \w", line):
            end = i
            break
    if start is None or end is None or end <= start:
        raise SystemExit("regiao de user data nao encontrada em 03-cluster.yml")
    body = []
    for line in lines[start:end]:
        body.append(line[14:] if len(line) > 14 else line.lstrip())
    return "\n".join(body)


def estimate(template_text, blob):
    lines = template_text.split("\n")
    script = template_script_region(lines)
    for token, sample in TOKENS.items():
        script = script.replace("${%s}" % token, sample)
    script = script.replace("${AppPayload}", blob)
    raw = len(script.encode("utf-8"))
    encoded = 4 * ((raw + 2) // 3)
    return raw, encoded


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stats", action="store_true",
                    help="apenas mede o tamanho; nao reescreve o template")
    args = ap.parse_args()

    blob, src_size, xz_size = build_payload()
    print("payload: %d bytes -> lzma %d -> base64 %d" % (src_size, xz_size, len(blob)))

    with open(TEMPLATE, "rb") as fh:
        raw_text = fh.read().decode("utf-8")

    new_text, count = re.subn(
        r"^([ \t]+AppPayload: ).*$",
        lambda m: "%s'%s'" % (m.group(1), blob),
        raw_text,
        flags=re.M,
    )
    if count != 1:
        raise SystemExit("linha 'AppPayload:' nao encontrada no template")

    size_raw, size_enc = estimate(new_text, blob)
    print("user data expandido: %d bytes; apos Base64: %d bytes (limite 16384)"
          % (size_raw, size_enc))
    if size_enc > 16384:
        raise SystemExit("ERRO: user data excede 16 KiB. Reduza o payload.")
    if size_raw > PAYLOAD_LIMIT_RAW:
        print("AVISO: folga menor que o recomendado (%d > %d)"
              % (size_raw, PAYLOAD_LIMIT_RAW))

    if args.stats:
        print("modo --stats: template nao gravado")
        return

    with open(TEMPLATE, "wb") as fh:
        fh.write(new_text.encode("utf-8"))
    print("03-cluster.yml atualizado com o payload embutido")


if __name__ == "__main__":
    main()
