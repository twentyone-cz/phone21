"""Přihlášení zařízení: každé zařízení má vlastní heslo, všechna vidí jeden
společný adresář a kalendář (uživatel SHARED). Správce zůstává sám sebou."""
import hashlib
import hmac
import os
import threading
import time

from radicale.auth import htpasswd

ADMIN = "_phone21"
SHARED = "spolecne"
CACHE_SECONDS = 60


class Auth(htpasswd.Auth):

    def __init__(self, configuration):
        super().__init__(configuration)
        self._p21_lock = threading.Lock()
        self._p21_cache = {}
        self._p21_salt = os.urandom(16)

    def _p21_stamp(self):
        st = os.stat(self._filename)
        return st.st_mtime_ns, st.st_size

    def _login(self, login, password):
        try:
            stamp = self._p21_stamp()
        except OSError:
            return ""
        digest = hmac.new(self._p21_salt, ("%s\0%s" % (login, password)).encode(),
                          hashlib.sha256).digest()
        now = time.monotonic()
        with self._p21_lock:
            hit = self._p21_cache.get(login)
        if (hit and hit[1] == stamp and now - hit[2] < CACHE_SECONDS
                and hmac.compare_digest(hit[0], digest)):
            user = login
        else:
            user = super()._login(login, password)
            with self._p21_lock:
                if user:
                    self._p21_cache[login] = (digest, stamp, now)
                else:
                    self._p21_cache.pop(login, None)
        if not user:
            return ""
        return ADMIN if user == ADMIN else SHARED
