#!/usr/bin/env python3
"""
Generate a jwt-policy.yaml AgentgatewayPolicy manifest with inline JWKS.

Fetches public keys from either a JWK Set URI or an OpenID Connect well-known
configuration URI, then serializes the full policy to YAML.

Usage:
    python3 New-JwtPolicyYaml.py \\
        --uri   https://idp.example.com/.well-known/openid-configuration \\
        --issuer  https://idp.example.com/ \\
        --audiences https://api.example.com

    python3 New-JwtPolicyYaml.py \\
        --uri   https://idp.example.com/.well-known/jwks.json \\
        --issuer  https://idp.example.com/ \\
        --audiences https://api.example.com https://gateway.example.com \\
        --output-path ./custom-jwt-policy.yaml

Dependencies:
    pip install pyyaml
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

try:
    import yaml
except ModuleNotFoundError:
    print(
        "Error: PyYAML is required. Install with: pip install pyyaml",
        file=sys.stderr,
    )
    sys.exit(1)


def _quoted_str_representer(dumper: yaml.Dumper, data: str) -> yaml.ScalarNode:
    """Force single-quoted style for strings containing JSON structural characters."""
    if any(c in data for c in "{}[]:,"):
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="'")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


def _build_dumper() -> type:
    dumper = yaml.Dumper
    dumper.add_representer(str, _quoted_str_representer)
    return dumper


def _fetch_json(uri: str) -> dict:
    try:
        with urllib.request.urlopen(uri) as response:
            return json.loads(response.read())
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Failed to fetch '{uri}': {exc}") from exc


def fetch_jwks(uri: str) -> list:
    """
    Fetch the JWK collection from a JWK Set URI or OpenID Connect
    well-known configuration URI. Follows jwks_uri automatically if present.
    """
    data = _fetch_json(uri)

    if "jwks_uri" in data:
        data = _fetch_json(data["jwks_uri"])

    if "keys" not in data:
        raise ValueError(f"No 'keys' field found in response from '{uri}'")

    return data["keys"]


def new_jwt_policy_yaml(
    uri: str,
    issuer: str,
    audiences: list,
    output_path: str,
) -> None:
    """
    Build and write the AgentgatewayPolicy JWT authentication manifest.

    Args:
        uri:         JWK Set URI or OpenID Connect well-known config URI.
        issuer:      Token issuer claim value (must match 'iss' in issued JWTs).
        audiences:   List of audience values (matches 'aud' claim in JWTs).
        output_path: Destination file path for the generated YAML.
    """
    print(f"Fetching JWK collection from {uri}", file=sys.stderr)
    keys = fetch_jwks(uri)
    jwk_set_json = json.dumps({"keys": keys}, separators=(",", ":"))

    policy = {
        "apiVersion": "agentgateway.dev/v1alpha1",
        "kind": "AgentgatewayPolicy",
        "metadata": {
            "name": "jwt-auth-policy",
            "namespace": "agentgateway-system",
        },
        "spec": {
            "targetRefs": [
                {
                    "group": "gateway.networking.k8s.io",
                    "kind": "Gateway",
                    "name": "agentgateway-proxy",
                }
            ],
            "traffic": {
                "jwtAuthentication": {
                    "mode": "Strict",
                    "providers": [
                        {
                            "issuer": issuer,
                            "audiences": audiences,
                            "jwks": {
                                "inline": jwk_set_json,
                            },
                        }
                    ],
                }
            },
        },
    }

    output_dir = os.path.dirname(output_path)
    if output_dir and not os.path.exists(output_dir):
        os.makedirs(output_dir)

    with open(output_path, "w", encoding="utf-8") as fh:
        yaml.dump(policy, fh, Dumper=_build_dumper(), default_flow_style=False, sort_keys=False)

    print(f"Written: {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a jwt-policy.yaml AgentgatewayPolicy manifest with inline JWKS.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--uri", "-u",
        required=True,
        metavar="URI",
        help="JWK Set URI or OpenID Connect well-known configuration URI.",
    )
    parser.add_argument(
        "--issuer", "-i",
        required=True,
        metavar="ISSUER",
        help="Token issuer claim value (must match 'iss' in issued JWTs).",
    )
    parser.add_argument(
        "--audiences", "-a",
        required=True,
        nargs="+",
        metavar="AUDIENCE",
        help="One or more audience values (matches 'aud' claim in JWTs).",
    )
    parser.add_argument(
        "--output-path", "-o",
        default=os.path.join(os.getcwd(), "jwt-policy.yaml"),
        metavar="PATH",
        help="Output file path (default: jwt-policy.yaml in current directory).",
    )

    args = parser.parse_args()
    new_jwt_policy_yaml(args.uri, args.issuer, args.audiences, args.output_path)


if __name__ == "__main__":
    main()
