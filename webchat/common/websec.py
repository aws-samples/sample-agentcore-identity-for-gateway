"""Shared web-security helpers for the GUI apps: inline-JSON escaping, session cookies, bounded in-memory stores."""
import json, threading, time, urllib.parse

SESSION_TTL, PENDING_TTL, MAX_ENTRIES = 3600, 600, 1000  # seconds, seconds, entries per store

_ESC = {"<": "\\u003c", ">": "\\u003e", "&": "\\u0026", "\u2028": "\\u2028", "\u2029": "\\u2029"}


def json_for_script(obj):
    """JSON safe to inline in <script> (JS or application/json): no '<', '>', '&', U+2028/2029 can appear."""
    return "".join(_ESC.get(ch, ch) for ch in json.dumps(obj))


def cookie(name, value, base_url, max_age=SESSION_TTL):
    """Set-Cookie value: HttpOnly + SameSite=Lax always, Secure whenever the public base URL is https."""
    secure = "Secure; " if base_url.startswith("https") else ""
    return f"{name}={value}; HttpOnly; {secure}SameSite=Lax; Path=/; Max-Age={max_age}"


# Anti-clickjacking / hardening headers for every response. No script-src: the pages rely on inline scripts.
SECURITY_HEADERS = (
    ("Content-Security-Policy", "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"),
    ("X-Frame-Options", "DENY"),
    ("X-Content-Type-Options", "nosniff"),
    ("Referrer-Policy", "no-referrer"),
)


def same_origin_post(headers, base_url):
    """CSRF guard for state-changing POSTs. Browsers always send Sec-Fetch-Site and/or Origin on POST; require them to say
    same-origin. Neither header present -> reject (fail closed)."""
    site = headers.get("Sec-Fetch-Site")
    if site is not None:
        return site == "same-origin"
    origin = headers.get("Origin")
    if origin is None:
        return False
    a, b = urllib.parse.urlparse(origin), urllib.parse.urlparse(base_url)
    return (a.scheme, a.netloc) == (b.scheme, b.netloc) and bool(a.netloc)


class TTLStore:
    """dict-like store with absolute expiry and a size cap (oldest entry evicted). Lazy cleanup, thread-safe."""

    def __init__(self, ttl, max_entries=MAX_ENTRIES, clock=time.monotonic):
        self.ttl, self.max, self.clock, self._d, self._lock = ttl, max_entries, clock, {}, threading.Lock()

    def _purge(self):
        now = self.clock()
        for k in [k for k, (exp, _) in self._d.items() if exp <= now]:
            del self._d[k]

    def __setitem__(self, key, value):
        with self._lock:
            self._purge()
            self._d.pop(key, None)
            while len(self._d) >= self.max:
                del self._d[next(iter(self._d))]  # dicts keep insertion order: oldest first
            self._d[key] = (self.clock() + self.ttl, value)

    def get(self, key, default=None):
        with self._lock:
            item = self._d.get(key)
            if item and item[0] <= self.clock():
                del self._d[key]; item = None
            return item[1] if item else default

    def pop(self, key, default=None):
        value = self.get(key, default)
        with self._lock:
            self._d.pop(key, None)
        return value

    def __len__(self):
        with self._lock:
            self._purge()
            return len(self._d)


def take_pending_3lo(s, clock=time.time):
    """One-time read of the 3LO session this browser session started (None if absent/expired). Always clears it."""
    uri, started = s.pop("pending_session_uri", None), s.pop("pending_at", 0)
    return uri if uri and clock() - started <= PENDING_TTL else None
