import sys
from typing import Any, Dict

import yaml

REQUIRED_TOP_LEVEL = ["container", "artifacts", "routing"]

def fail(msg: str) -> None:
    print(f"YAML schema validation failed: {msg}", file=sys.stderr)
    sys.exit(1)

def is_int(x: Any) -> bool:
    # YAML can parse ints as int already; reject bool since it's a subclass of int in Python.
    return isinstance(x, int) and not isinstance(x, bool)

def expect_str(obj: Dict[str, Any], path: str, key: str) -> str:
    if key not in obj:
        fail(f"Missing '{path}.{key}'")
    val = obj[key]
    if not isinstance(val, str) or val.strip() == "":
        fail(f"Expected '{path}.{key}' to be a non-empty string, got: {type(val).__name__} ({val!r})")
    return val

def expect_int(obj: Dict[str, Any], path: str, key: str) -> int:
    if key not in obj:
        fail(f"Missing '{path}.{key}'")
    val = obj[key]
    if not is_int(val):
        fail(f"Expected '{path}.{key}' to be an integer, got: {type(val).__name__} ({val!r})")
    return val

def expect_dict(obj: Dict[str, Any], path: str, key: str) -> Dict[str, Any]:
    if key not in obj:
        fail(f"Missing '{path}.{key}'")
    val = obj[key]
    if not isinstance(val, dict):
        fail(f"Expected '{path}.{key}' to be a mapping/object, got: {type(val).__name__} ({val!r})")
    return val

def validate_model_entry(entry_key: str, entry_val: Any) -> None:
    path = entry_key

    if not isinstance(entry_val, dict):
        fail(f"Top-level key '{entry_key}' must map to an object, got {type(entry_val).__name__}")

    # required top-level keys
    for k in REQUIRED_TOP_LEVEL:
        if k not in entry_val:
            fail(f"Missing '{path}.{k}'")

    container = expect_dict(entry_val, path, "container")
    expect_str(container, f"{path}.container", "litserve_image")

    artifacts = expect_dict(entry_val, path, "artifacts")
    expect_str(artifacts, f"{path}.artifacts", "s3_bucket")

    routing = expect_dict(entry_val, path, "routing")
    expect_int(routing, f"{path}.routing", "priority")

def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-yaml>", file=sys.stderr)
        sys.exit(2)

    yaml_path = sys.argv[1]

    try:
        with open(yaml_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        fail(f"File not found: {yaml_path}")
    except yaml.YAMLError as e:
        fail(f"YAML parse error: {e}")

    if not isinstance(data, dict) or not data:
        fail("Root YAML must be a non-empty mapping/object of models")

    for k, v in data.items():
        validate_model_entry(str(k), v)

    print(f"YAML schema validation passed for {len(data)} models: {', '.join(data.keys())}")

if __name__ == "__main__":
    main()