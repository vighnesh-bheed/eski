import argparse
from pathlib import Path
import subprocess


def generate(destination):
    target = Path(destination).resolve()
    target.mkdir(parents=True, exist_ok=False)
    def openssl(*arguments):
        subprocess.run(['openssl', *map(str, arguments)], cwd=target, check=True)
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2',
            '-subj', '/CN=Eski managed fixture CA', '-keyout', 'ca.key', '-out', 'ca.crt',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
            '-addext', 'subjectKeyIdentifier=hash')
    for name, usage in (('server', 'serverAuth'), ('client', 'clientAuth'), ('redis', 'serverAuth,clientAuth')):
        extensions = target / (name + '.ext')
        extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
                              'extendedKeyUsage=' + usage + '\nsubjectAltName=IP:127.0.0.1,IP:::1,DNS:localhost\n')
        openssl('req', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=' + name,
                '-keyout', name + '.key', '-out', name + '.csr')
        openssl('x509', '-req', '-sha256', '-days', '2', '-in', name + '.csr',
                '-CA', 'ca.crt', '-CAkey', 'ca.key', '-CAcreateserial',
                '-extfile', extensions, '-out', name + '.crt')
    openssl('genpkey', '-genparam', '-algorithm', 'DH', '-pkeyopt', 'group:ffdhe2048', '-out', 'redis.dh')
    for key in target.glob('*.key'):
        key.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description='Generate strict fixture PKI for actual upstream TLS tests.')
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    generate(args.destination)


if __name__ == '__main__':
    main()
