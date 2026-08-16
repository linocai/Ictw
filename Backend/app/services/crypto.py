from __future__ import annotations

import base64
import hashlib

from cryptography.fernet import Fernet, InvalidToken

from app.config import get_settings


class SecretUndecryptable(Exception):
    """The stored ciphertext does not belong to the current KEK_SECRET.

    Raised on KEK rotation and when a production database is restored onto a
    host holding a different key. Both are routine operations that previously
    surfaced as a bare 500 with an empty message.
    """


def _fernet() -> Fernet:
    digest = hashlib.sha256(get_settings().kek_secret.encode("utf-8")).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt_secret(value: str) -> str:
    return _fernet().encrypt(value.encode("utf-8")).decode("utf-8")


def decrypt_secret(value: str) -> str:
    try:
        return _fernet().decrypt(value.encode("utf-8")).decode("utf-8")
    except (InvalidToken, ValueError) as exc:
        raise SecretUndecryptable("api key cannot be decrypted with the current KEK_SECRET") from exc
