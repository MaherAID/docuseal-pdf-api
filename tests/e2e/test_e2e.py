"""End-to-end test of docuseal-pdf-api.

Runs as the compose service "e2e" (started by tests/e2e/run.sh) inside the compose network:
the app is reachable at APP_URL, webhook deliveries are read from the receiver at RECEIVER_URL.
Secrets arrive through environment variables and are never printed.

Flow: validation/auth errors -> POST /api/templates/pdf -> GET /api/templates/:id ->
POST /api/submissions -> signing page + form view -> PUT /api/submitters/:id (complete) ->
webhooks (HMAC verified) -> signed documents; plus a declined and an expired submission to
capture form.declined and submission.expired.
"""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from http.cookiejar import CookieJar
from typing import Any

from testpdf import build_pdf

APP_URL = os.environ["APP_URL"].rstrip("/")
RECEIVER_URL = os.environ["RECEIVER_URL"].rstrip("/")
API_TOKEN = os.environ["E2E_API_TOKEN"]
WEBHOOK_SECRET = os.environ["E2E_WEBHOOK_SECRET"]
HMAC_SECRET = os.environ["E2E_WEBHOOK_HMAC_SECRET"]
EXPECTED_SOURCE_URL = os.environ.get("EXPECTED_SOURCE_URL") or "https://github.com/MaherAID/docuseal-pdf-api"
OUT_DIR = os.environ.get("E2E_OUT_DIR", "")

WEBHOOK_SECRET_HEADER = "x-e2e-webhook-secret"  # noqa: S105 - a header name, not a secret
SIGNATURE_HEADER = "x-docuseal-signature"
SIGNATURE_TOLERANCE_SECONDS = 300
WEBHOOK_TIMEOUT_SECONDS = 180
APP_TIMEOUT_SECONDS = 180
FLOAT_TOLERANCE = 1e-9
MAX_FILE_BYTES = 20 * 1024 * 1024

ROLE_CUSTOMER = "Kunde"
ROLE_COMPANY = "Auto-i-DAT"

# Areas relative to the page (0..1, origin top-left); pages 1-based as sent to the API.
CUSTOMER_DATE_AREA = {"x": 0.10, "y": 0.20, "w": 0.30, "h": 0.04, "page": 1}
CUSTOMER_SIGNATURE_AREA = {"x": 0.10, "y": 0.75, "w": 0.35, "h": 0.08, "page": 2}
COMPANY_SIGNATURE_AREA = {"x": 0.55, "y": 0.75, "w": 0.35, "h": 0.08, "page": 2}


# --------------------------------------------------------------------------- helpers


@dataclass
class Response:
    status: int
    headers: dict[str, str]
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body)

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:  # noqa: ARG002 - stop at the 3xx
        return None


def send(
    method: str,
    url: str,
    *,
    json_body: Any = None,
    form: dict[str, str] | None = None,
    auth: bool = True,
    token: str | None = None,
    accept: str = "application/json",
    follow_redirects: bool = True,
    cookies: CookieJar | None = None,
    timeout: float = 120,
) -> Response:
    if not url.startswith("http"):
        url = APP_URL + url
    headers = {"Accept": accept}
    data = None
    if json_body is not None:
        data = json.dumps(json_body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if auth:
        headers["X-Auth-Token"] = token if token is not None else API_TOKEN
    handlers: list[urllib.request.BaseHandler] = []
    if not follow_redirects:
        handlers.append(_NoRedirect())
    if cookies is not None:
        handlers.append(urllib.request.HTTPCookieProcessor(cookies))
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with opener.open(request, timeout=timeout) as response:
            return Response(response.status, _lower(response.headers.items()), response.read())
    except urllib.error.HTTPError as error:
        return Response(error.code, _lower(error.headers.items()), error.read())


def _lower(items: Any) -> dict[str, str]:
    return {key.lower(): value for key, value in items}


def app_url(url: str) -> str:
    """Rewrite an absolute URL from the app to APP_URL (same path), keeping the test network-agnostic."""
    parsed = urllib.parse.urlsplit(url)
    return APP_URL + parsed.path + (f"?{parsed.query}" if parsed.query else "")


class Checks:
    def __init__(self) -> None:
        self.count = 0

    def __call__(self, condition: object, message: str) -> None:
        if not condition:
            raise AssertionError(message)
        self.count += 1
        print(f"  ok   {message}", flush=True)


check = Checks()


def step(title: str) -> None:
    print(f"\n== {title}", flush=True)


def wait_until(predicate: Callable[[], Any], timeout: float, interval: float = 1.0) -> Any:
    deadline = time.monotonic() + timeout
    while True:
        result = predicate()
        if result:
            return result
        if time.monotonic() > deadline:
            return None
        time.sleep(interval)


def approx(a: float, b: float) -> bool:
    return abs(a - b) <= FLOAT_TOLERANCE


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def fetch_bytes(url: str) -> Response:
    return send("GET", app_url(url), auth=False, accept="*/*")


def is_pdf(data: bytes) -> bool:
    return data.startswith(b"%PDF-")


# --------------------------------------------------------------------------- payloads

CONTRACT_PDF = build_pdf(
    [
        ("E2E Vertrag 4711 - Seite 1", [tuple(CUSTOMER_DATE_AREA[k] for k in "xywh")]),
        (
            "E2E Vertrag 4711 - Seite 2",
            [tuple(CUSTOMER_SIGNATURE_AREA[k] for k in "xywh"), tuple(COMPANY_SIGNATURE_AREA[k] for k in "xywh")],
        ),
    ]
)
TERMS_PDF = build_pdf([("E2E AGB", [])])


def contract_fields() -> list[dict[str, Any]]:
    return [
        {"name": "Datum Kunde", "type": "date", "role": ROLE_CUSTOMER, "areas": [dict(CUSTOMER_DATE_AREA)]},
        {
            "name": "Unterschrift Kunde",
            "type": "signature",
            "role": ROLE_CUSTOMER,
            "required": True,
            "areas": [dict(CUSTOMER_SIGNATURE_AREA)],
        },
        {
            "name": "Unterschrift Auto-i-DAT",
            "type": "signature",
            "role": ROLE_COMPANY,
            "areas": [dict(COMPANY_SIGNATURE_AREA)],
        },
    ]


def template_payload() -> dict[str, Any]:
    return {
        "name": "E2E Vertrag 4711",
        "external_id": "contract-4711",
        "folder_name": "E2E",
        "flatten": False,
        "remove_tags": True,
        "documents": [
            {"name": "Vertrag 4711", "file": b64(CONTRACT_PDF), "fields": contract_fields()},
            {"name": "AGB", "file": b64(TERMS_PDF)},
        ],
    }


# --------------------------------------------------------------------------- webhooks


@dataclass
class Delivery:
    event_type: str
    data: dict[str, Any]
    payload: dict[str, Any]
    headers: dict[str, str]
    raw: bytes
    received_at: float


def deliveries() -> list[Delivery]:
    response = send("GET", f"{RECEIVER_URL}/deliveries", auth=False)
    result = []
    for record in response.json():
        raw = base64.b64decode(record["body_b64"])
        payload = json.loads(raw)
        result.append(
            Delivery(
                payload.get("event_type", ""),
                payload.get("data") or {},
                payload,
                record["headers"],
                raw,
                record["received_at"],
            )
        )
    return result


def wait_for_delivery(event_type: str, predicate: Callable[[Delivery], bool]) -> Delivery:
    def find() -> Delivery | None:
        return next((d for d in deliveries() if d.event_type == event_type and predicate(d)), None)

    delivery = wait_until(find, WEBHOOK_TIMEOUT_SECONDS, interval=1.0)
    check(delivery is not None, f"webhook {event_type} delivered")
    assert delivery is not None
    return delivery


def signature_valid(delivery: Delivery, secret: str) -> bool:
    header = delivery.headers.get(SIGNATURE_HEADER, "")
    timestamp, _, digest = header.partition(".")
    if not timestamp.isdigit() or not digest:
        return False
    expected = hmac.new(secret.encode(), timestamp.encode() + b"." + delivery.raw, hashlib.sha256).hexdigest()
    fresh = abs(delivery.received_at - int(timestamp)) <= SIGNATURE_TOLERANCE_SECONDS
    return fresh and hmac.compare_digest(expected, digest)


def verify_delivery(delivery: Delivery) -> None:
    label = f"{delivery.event_type} delivery"
    check(delivery.headers.get("user-agent") == "DocuSeal.com Webhook", f"{label}: User-Agent is DocuSeal.com Webhook")
    check(delivery.headers.get("content-type", "").startswith("application/json"), f"{label}: JSON content type")
    check(delivery.headers.get(WEBHOOK_SECRET_HEADER) == WEBHOOK_SECRET, f"{label}: custom secret header present")
    check(signature_valid(delivery, HMAC_SECRET), f"{label}: X-Docuseal-Signature is a valid HMAC-SHA256")
    check(
        set(delivery.payload) == {"event_type", "timestamp", "data"}, f"{label}: envelope is event_type/timestamp/data"
    )


# --------------------------------------------------------------------------- tests


def wait_for_app() -> None:
    step("wait for the app")
    ready = wait_until(lambda: send("GET", "/up", auth=False, accept="*/*").status == 200, APP_TIMEOUT_SECONDS, 2)
    check(ready, "GET /up returns 200")


def test_authentication() -> None:
    step("authentication")
    response = send("POST", "/api/templates/pdf", json_body=template_payload(), auth=False)
    check(response.status == 401, f"without X-Auth-Token -> 401 (got {response.status})")
    check(response.json().get("error") == "Not authenticated", "error message 'Not authenticated'")
    response = send("POST", "/api/templates/pdf", json_body=template_payload(), token="wrong-token")  # noqa: S106
    check(response.status == 401, f"with an unknown token -> 401 (got {response.status})")


def template_count() -> int:
    response = send("GET", "/api/templates?limit=100")
    check(response.status == 200, "GET /api/templates -> 200")
    return len(response.json()["data"])


def test_validation_errors() -> None:
    step("validation errors -> 422")
    before = template_count()

    def mutate(change: Callable[[dict[str, Any]], None]) -> dict[str, Any]:
        payload = template_payload()
        change(payload)
        return payload

    def field(payload: dict[str, Any], index: int = 0) -> dict[str, Any]:
        return payload["documents"][0]["fields"][index]

    oversized = b"%PDF-" + b"\0" * (MAX_FILE_BYTES + 1)
    cases: list[tuple[str, dict[str, Any], str]] = [
        ("missing name", mutate(lambda p: p.pop("name")), "name is required"),
        ("no documents", mutate(lambda p: p.update(documents=[])), "documents must be a non-empty array"),
        (
            "invalid base64",
            mutate(lambda p: p["documents"][0].update(file="%%%not-base64%%%")),
            "documents[0].file is not valid base64",
        ),
        (
            "not a PDF",
            mutate(lambda p: p["documents"][0].update(file=b64(b"hello world"))),
            "documents[0].file is not a PDF",
        ),
        (
            "file too large",
            mutate(lambda p: p["documents"][0].update(file=b64(oversized))),
            "documents[0].file exceeds the maximum size of 20 MB",
        ),
        (
            "unknown field type",
            mutate(lambda p: field(p).update(type="fingerprint")),
            "documents[0].fields[0].type must be one of",
        ),
        ("missing role", mutate(lambda p: field(p).pop("role")), "documents[0].fields[0].role is required"),
        ("blank role", mutate(lambda p: field(p).update(role="  ")), "documents[0].fields[0].role is required"),
        (
            "page beyond the document",
            mutate(lambda p: field(p)["areas"][0].update(page=3)),
            "documents[0].fields[0].areas[0].page must be an integer between 1 and 2",
        ),
        (
            "page 0",
            mutate(lambda p: field(p)["areas"][0].update(page=0)),
            "documents[0].fields[0].areas[0].page must be an integer between 1 and 2",
        ),
        (
            "pixel instead of relative coordinates",
            mutate(lambda p: field(p)["areas"][0].update(x=120)),
            "documents[0].fields[0].areas[0].x must be a number from 0 up to 1",
        ),
        (
            "area wider than the page",
            mutate(lambda p: field(p)["areas"][0].update(x=0.9, w=0.2)),
            "documents[0].fields[0].areas[0] exceeds the page width",
        ),
        (
            "zero height",
            mutate(lambda p: field(p)["areas"][0].update(h=0)),
            "documents[0].fields[0].areas[0].h must be a number greater than 0 up to 1",
        ),
        ("no fields at all", mutate(lambda p: p["documents"][0].pop("fields")), "must define at least one field"),
        (
            "options on a text field",
            mutate(lambda p: field(p).update(type="text", options=["a"])),
            "documents[0].fields[0].options is only supported for select, radio, multiple fields",
        ),
        (
            "select without options",
            mutate(lambda p: field(p).update(type="select")),
            "documents[0].fields[0].options must not be empty for select fields",
        ),
        (
            "radio areas without option",
            mutate(
                lambda p: field(p).update(
                    type="radio", options=["Ja"], areas=[dict(CUSTOMER_DATE_AREA), dict(CUSTOMER_DATE_AREA, x=0.5)]
                )
            ),
            "documents[0].fields[0].areas[].option is required",
        ),
        (
            "roles differing only in case",
            mutate(lambda p: field(p, 2).update(role="kunde")),
            "roles must be unique ignoring case",
        ),
    ]
    for description, payload, expected in cases:
        response = send("POST", "/api/templates/pdf", json_body=payload)
        body = response.json() if response.body else {}
        check(response.status == 422, f"{description}: status 422 (got {response.status})")
        check(
            expected in str(body.get("error", "")),
            f"{description}: error mentions '{expected}' (got {body.get('error')!r})",
        )

    response = send("POST", "/api/templates/pdf", json_body=mutate(lambda p: (p.pop("name"), field(p).pop("role"))))
    errors = response.json().get("errors", [])
    check(response.status == 422 and len(errors) >= 2, f"all problems are reported at once (errors={errors})")
    check(template_count() == before, "rejected requests created no template")


def test_create_template() -> dict[str, Any]:
    step("POST /api/templates/pdf")
    payload = template_payload()
    started = time.monotonic()
    response = send("POST", "/api/templates/pdf", json_body=payload)
    check(response.status == 200, f"create template -> 200 (got {response.status}: {response.text()[:300]})")
    print(f"       created in {time.monotonic() - started:.1f}s", flush=True)
    template = response.json()

    check(template["name"] == "E2E Vertrag 4711", "name is stored")
    check(template["external_id"] == "contract-4711", "external_id is stored")
    check(template["folder_name"] == "E2E", "folder_name is applied")
    check(template["source"] == "api", "source is 'api'")

    submitters = template["submitters"]
    check(
        [s["name"] for s in submitters] == [ROLE_CUSTOMER, ROLE_COMPANY],
        "one template submitter per distinct role, in order of first appearance",
    )
    check(
        all(s.get("uuid") for s in submitters) and len({s["uuid"] for s in submitters}) == 2, "submitter uuids are set"
    )
    role_uuid = {s["name"]: s["uuid"] for s in submitters}

    schema = template["schema"]
    check([item["name"] for item in schema] == ["Vertrag 4711", "AGB"], "schema lists both documents in order")
    contract_uuid = schema[0]["attachment_uuid"]

    fields = {f["name"]: f for f in template["fields"]}
    check(set(fields) == {"Datum Kunde", "Unterschrift Kunde", "Unterschrift Auto-i-DAT"}, "three fields created")
    expectations = [
        ("Datum Kunde", "date", ROLE_CUSTOMER, CUSTOMER_DATE_AREA),
        ("Unterschrift Kunde", "signature", ROLE_CUSTOMER, CUSTOMER_SIGNATURE_AREA),
        ("Unterschrift Auto-i-DAT", "signature", ROLE_COMPANY, COMPANY_SIGNATURE_AREA),
    ]
    for name, field_type, role, area_in in expectations:
        created = fields[name]
        check(created["type"] == field_type, f"{name}: type {field_type}")
        check(created["submitter_uuid"] == role_uuid[role], f"{name}: submitter_uuid of role {role}")
        check(created["required"] is True, f"{name}: required (default true)")
        check(len(created["areas"]) == 1, f"{name}: one area")
        area = created["areas"][0]
        check(area["attachment_uuid"] == contract_uuid, f"{name}: area.attachment_uuid points to the contract")
        check(area["page"] == area_in["page"] - 1, f"{name}: API page {area_in['page']} -> stored page {area['page']}")
        check(all(approx(area[k], area_in[k]) for k in "xywh"), f"{name}: x/y/w/h stored unchanged")

    documents = template["documents"]
    check([d["uuid"] for d in documents] == [item["attachment_uuid"] for item in schema], "documents match the schema")
    check(documents[0]["filename"] == "Vertrag 4711.pdf", "document filename derived from the name")
    stored = fetch_bytes(documents[0]["url"])
    check(
        stored.status == 200 and hashlib.sha256(stored.body).digest() == hashlib.sha256(CONTRACT_PDF).digest(),
        "stored contract PDF is byte-identical to the upload",
    )
    check(all(d.get("preview_image_url") for d in documents), "preview images were generated for every document")
    preview = fetch_bytes(documents[0]["preview_image_url"])
    check(
        preview.status == 200 and (preview.body[:4] == b"\x89PNG" or preview.body[:3] == b"\xff\xd8\xff"),
        "first page preview is an image",
    )
    return template


def test_get_template(created: dict[str, Any]) -> None:
    step("GET /api/templates/:id")
    response = send("GET", f"/api/templates/{created['id']}")
    check(response.status == 200, "GET /api/templates/:id -> 200")
    fetched = response.json()
    for key in (
        "id",
        "slug",
        "name",
        "external_id",
        "folder_name",
        "source",
        "submitters",
        "fields",
        "schema",
        "preferences",
        "author_id",
        "archived_at",
    ):
        check(fetched[key] == created[key], f"GET returns the same {key}")
    strip = [{k: d[k] for k in ("id", "uuid", "filename")} for d in created["documents"]]
    check(
        [{k: d[k] for k in ("id", "uuid", "filename")} for d in fetched["documents"]] == strip,
        "GET returns the same documents",
    )


def create_submission(template_id: int, **extra: Any) -> list[dict[str, Any]]:
    payload = {
        "template_id": template_id,
        "send_email": False,
        "order": "preserved",
        "submitters": [
            {"role": ROLE_CUSTOMER, "email": "kunde@example.com", "name": "Max Muster"},
            {"role": ROLE_COMPANY, "email": "vertrag@example.com", "name": "Auto-i-DAT AG"},
        ],
        **extra,
    }
    response = send("POST", "/api/submissions", json_body=payload)
    check(response.status == 200, f"POST /api/submissions -> 200 (got {response.status}: {response.text()[:300]})")
    return response.json()


def test_submission(template: dict[str, Any]) -> list[dict[str, Any]]:
    step("POST /api/submissions")
    submitters = create_submission(template["id"])
    check(len(submitters) == 2, "two submitters returned")
    check([s["role"] for s in submitters] == [ROLE_CUSTOMER, ROLE_COMPANY], "submitters carry their roles")
    check(len({s["submission_id"] for s in submitters}) == 1, "both submitters belong to one submission")
    for submitter in submitters:
        check(bool(submitter.get("slug")), f"{submitter['role']}: slug present")
        check(
            urllib.parse.urlsplit(submitter.get("embed_src", "")).path == f"/s/{submitter['slug']}",
            f"{submitter['role']}: embed_src points to /s/<slug>",
        )
    return submitters


def test_signing_page(submitter: dict[str, Any]) -> None:
    step("signing page")
    page = send("GET", app_url(submitter["embed_src"]), auth=False, accept="text/html")
    check(page.status == 200, f"GET /s/<slug> -> 200 (got {page.status})")
    body = page.text()
    check("<submission-form" in body, "signing form is rendered")
    check('href="https://www.docuseal.com/start"' in body, "upstream 'Powered by DocuSeal' attribution is present")
    check(
        f'href="{html.escape(EXPECTED_SOURCE_URL)}"' in body and 'data-docuseal-pdf-api="source-offer"' in body,
        "AGPL source code link is shown below the attribution",
    )

    token = re.search(r'data-view-token="([^"]+)"', body)
    check(token is not None, "view token present")
    assert token is not None
    view = send("POST", f"/s/{submitter['slug']}/view", json_body={"v": html.unescape(token.group(1))}, auth=False)
    check(view.status == 200, f"POST /s/<slug>/view (what the browser sends) -> 200 (got {view.status})")

    source = send("GET", "/source", auth=False, accept="*/*", follow_redirects=False)
    check(
        source.status == 302 and source.headers.get("location") == EXPECTED_SOURCE_URL,
        f"GET /source redirects to {EXPECTED_SOURCE_URL}",
    )


def complete(submitter: dict[str, Any], values: dict[str, str]) -> dict[str, Any]:
    response = send("PUT", f"/api/submitters/{submitter['id']}", json_body={"completed": True, "values": values})
    check(
        response.status == 200,
        f"PUT /api/submitters/{submitter['id']} completed -> 200 (got {response.status}: {response.text()[:300]})",
    )
    body = response.json()
    check(body.get("completed_at") and body.get("status") == "completed", f"{submitter['role']} is completed")
    return body


def test_completion_and_webhooks(template: dict[str, Any], submitters: list[dict[str, Any]]) -> None:
    customer, company = submitters
    submission_id = customer["submission_id"]

    step("webhook: template.created")
    verify_delivery(wait_for_delivery("template.created", lambda d: d.data.get("id") == template["id"]))

    step("webhook: form.viewed")
    viewed = wait_for_delivery("form.viewed", lambda d: d.data.get("id") == customer["id"])
    verify_delivery(viewed)
    check(viewed.data.get("opened_at"), "form.viewed: opened_at is set")

    step("complete both submitters via PUT /api/submitters/:id")
    complete(customer, {"Datum Kunde": "2026-10-20", "Unterschrift Kunde": "Max Muster"})
    complete(company, {"Unterschrift Auto-i-DAT": "Auto-i-DAT AG"})

    step("webhooks: form.completed and submission.completed")
    for submitter in submitters:
        delivery = wait_for_delivery("form.completed", lambda d, s=submitter: d.data.get("id") == s["id"])
        verify_delivery(delivery)
        data = delivery.data
        check(
            data["status"] == "completed" and data["role"] == submitter["role"],
            f"form.completed ({submitter['role']}): status/role",
        )
        check(data["template"]["id"] == template["id"], f"form.completed ({submitter['role']}): template id")
        check(data["submission"]["id"] == submission_id, f"form.completed ({submitter['role']}): submission id")
        check(
            data["documents"] and all(is_pdf(fetch_bytes(doc["url"]).body) for doc in data["documents"]),
            f"form.completed ({submitter['role']}): signed documents download as PDF",
        )
    customer_values = {
        v["field"]: v["value"]
        for v in wait_for_delivery("form.completed", lambda d: d.data.get("id") == customer["id"]).data["values"]
    }
    check(customer_values.get("Datum Kunde") == "2026-10-20", "form.completed: date value reported")
    check(str(customer_values.get("Unterschrift Kunde", "")).startswith("http"), "form.completed: signature as URL")

    completed = wait_for_delivery("submission.completed", lambda d: d.data.get("id") == submission_id)
    verify_delivery(completed)
    data = completed.data
    check(data["status"] == "completed", "submission.completed: status completed")
    check([s["status"] for s in data["submitters"]] == ["completed", "completed"], "submission.completed: all signed")
    check(
        data["documents"] and all(is_pdf(fetch_bytes(doc["url"]).body) for doc in data["documents"]),
        "submission.completed: documents download as PDF",
    )
    check(is_pdf(fetch_bytes(data["audit_log_url"]).body), "submission.completed: audit log is a PDF")

    step("GET /api/submissions/:id/documents")
    response = send("GET", f"/api/submissions/{submission_id}/documents")
    check(response.status == 200, "GET /api/submissions/:id/documents -> 200")
    documents = response.json()["documents"]
    check(len(documents) == 2, "two signed documents (contract and terms)")
    for document in documents:
        downloaded = fetch_bytes(document["url"])
        check(downloaded.status == 200 and is_pdf(downloaded.body), f"signed document '{document['name']}' is a PDF")
        check(b"/ByteRange" in downloaded.body, f"signed document '{document['name']}' carries a digital signature")
    submission = send("GET", f"/api/submissions/{submission_id}").json()
    check(submission["status"] == "completed", "GET /api/submissions/:id reports completed")


def test_declined(template: dict[str, Any]) -> None:
    step("form.declined (decline on the signing page)")
    customer = create_submission(template["id"])[0]
    jar = CookieJar()
    page = send("GET", app_url(customer["embed_src"]), auth=False, accept="text/html", cookies=jar)
    check(page.status == 200, "signing page loads")
    decline_action = re.escape(f"/s/{customer['slug']}/decline")
    form = re.search(rf'<form[^>]*action="{decline_action}"[^>]*>(.*?)</form>', page.text(), re.S)
    check(form is not None, "decline form present")
    assert form is not None
    token = re.search(r'name="authenticity_token"[^>]*value="([^"]+)"', form.group(1))
    check(token is not None, "decline form carries a CSRF token")
    assert token is not None
    reason = "E2E: Vertrag abgelehnt"
    response = send(
        "POST",
        f"/s/{customer['slug']}/decline",
        auth=False,
        accept="text/html",
        cookies=jar,
        follow_redirects=False,
        form={"authenticity_token": html.unescape(token.group(1)), "reason": reason},
    )
    check(response.status in (302, 303), f"decline accepted (got {response.status})")
    declined = wait_for_delivery("form.declined", lambda d: d.data.get("id") == customer["id"])
    verify_delivery(declined)
    check(
        declined.data.get("status") == "declined" and declined.data.get("decline_reason") == reason,
        "form.declined: status declined with the reason",
    )


def test_expired(template: dict[str, Any]) -> None:
    step("submission.expired (expire_at a few seconds ahead)")
    expire_at = (dt.datetime.now(dt.UTC) + dt.timedelta(seconds=5)).isoformat(timespec="seconds")
    customer = create_submission(template["id"], expire_at=expire_at)[0]
    expired = wait_for_delivery("submission.expired", lambda d: d.data.get("id") == customer["submission_id"])
    verify_delivery(expired)
    check(expired.data.get("status") == "expired", "submission.expired: status expired")


def rich_fields() -> list[dict[str, Any]]:
    """One field per supported builder feature: preferences, options, area options, cells, datenow."""

    def area(x: float, y: float, w: float = 0.3, h: float = 0.04, page: int = 1, **extra: Any) -> dict[str, Any]:
        return {"x": x, "y": y, "w": w, "h": h, "page": page, **extra}

    return [
        {
            "name": "Kennzeichen",
            "type": "text",
            "role": ROLE_CUSTOMER,
            "title": "Kontrollschild",
            "description": "Wie im Fahrzeugausweis",
            "preferences": {"font_size": 12, "align": "center", "unknown": 1},
            "validation": {"pattern": "[A-Z]{2}[0-9]+", "message": "z. B. ZH12345"},
            "areas": [area(0.1, 0.10)],
        },
        {"name": "Kilometer", "type": "number", "role": ROLE_CUSTOMER, "areas": [area(0.5, 0.10)]},
        {
            "name": "Vertragsbeginn",
            "type": "date",
            "role": ROLE_CUSTOMER,
            "preferences": {"format": "DD.MM.YYYY"},
            "areas": [area(0.1, 0.16)],
        },
        {"name": "Newsletter", "type": "checkbox", "role": ROLE_CUSTOMER, "areas": [area(0.5, 0.16, 0.03, 0.02)]},
        {
            "name": "Paket",
            "type": "select",
            "role": ROLE_CUSTOMER,
            "options": ["Basis", "Premium"],
            "areas": [area(0.1, 0.22)],
        },
        {
            "name": "Zustimmung",
            "type": "radio",
            "role": ROLE_CUSTOMER,
            "areas": [area(0.1, 0.28, 0.03, 0.02, option="Ja"), area(0.2, 0.28, 0.03, 0.02, option="Nein")],
        },
        {
            "name": "Zusatz",
            "type": "multiple",
            "role": ROLE_CUSTOMER,
            "options": ["Glas", "Reifen"],
            "areas": [area(0.1, 0.34, 0.03, 0.02), area(0.2, 0.34, 0.03, 0.02)],
        },
        {"name": "PLZ", "type": "cells", "role": ROLE_CUSTOMER, "areas": [area(0.1, 0.40, 0.2, 0.04)]},
        {"name": "Kürzel", "type": "initials", "role": ROLE_CUSTOMER, "areas": [area(0.1, 0.46, 0.1, 0.04)]},
        {"name": "Unterzeichnet am", "type": "datenow", "role": ROLE_CUSTOMER, "areas": [area(0.1, 0.52)]},
    ]


def test_field_types() -> None:
    step("field types: options, area options, cells, datenow, preferences")
    payload = {
        "name": "E2E Feldtypen",
        "shared_link": True,
        "documents": [{"name": "Feldtypen", "file": b64(build_pdf([("E2E Feldtypen", [])])), "fields": rich_fields()}],
    }
    response = send("POST", "/api/templates/pdf", json_body=payload)
    check(
        response.status == 200,
        f"create template with all option types -> 200 (got {response.status}: {response.text()[:300]})",
    )
    template = response.json()
    check(template["shared_link"] is True, "shared_link is stored")
    fields = {f["name"]: f for f in template["fields"]}

    text = fields["Kennzeichen"]
    check(text["title"] == "Kontrollschild" and text["description"] == "Wie im Fahrzeugausweis", "title/description")
    check(text["preferences"] == {"font_size": 12, "align": "center"}, "known preferences kept, unknown ones dropped")
    check(text["validation"] == {"pattern": "[A-Z]{2}[0-9]+", "message": "z. B. ZH12345"}, "validation stored")
    check(fields["Newsletter"]["required"] is False, "checkbox is optional by default")
    check([o["value"] for o in fields["Paket"]["options"]] == ["Basis", "Premium"], "select options stored")

    radio = fields["Zustimmung"]
    radio_options = {o["value"]: o["uuid"] for o in radio["options"]}
    check(list(radio_options) == ["Ja", "Nein"], "radio options derived from areas[].option")
    check(
        [a["option_uuid"] for a in radio["areas"]] == [radio_options["Ja"], radio_options["Nein"]],
        "radio areas reference their option",
    )
    multiple = fields["Zusatz"]
    check(
        [a["option_uuid"] for a in multiple["areas"]] == [o["uuid"] for o in multiple["options"]],
        "multiple areas map to options by position",
    )
    check(fields["PLZ"]["areas"][0].get("cell_w", 0) > 0, "cells field gets a default cell width")
    datenow = fields["Unterzeichnet am"]
    check(
        datenow["type"] == "date" and datenow["readonly"] is True and datenow["default_value"] == "{{date}}",
        "datenow becomes a read-only date with the {{date}} placeholder",
    )

    response = send(
        "POST",
        "/api/submissions",
        json_body={
            "template_id": template["id"],
            "send_email": False,
            "submitters": [{"role": ROLE_CUSTOMER, "email": "kunde@example.com"}],
        },
    )
    check(response.status == 200, f"submission for the field type template -> 200 (got {response.status})")
    submitter = response.json()[0]
    page = send("GET", app_url(submitter["embed_src"]), auth=False, accept="text/html")
    check(page.status == 200 and "<submission-form" in page.text(), "signing form renders all field types")

    complete(
        submitter,
        {
            "Kennzeichen": "ZH12345",
            "Kilometer": "48000",
            "Vertragsbeginn": "01.11.2026",
            "Newsletter": True,
            "Paket": "Premium",
            "Zustimmung": "Ja",
            "Zusatz": ["Glas"],
            "PLZ": "8001",
            "Kürzel": "MM",
        },
    )
    delivery = wait_for_delivery("form.completed", lambda d: d.data.get("id") == submitter["id"])
    values = {v["field"]: v["value"] for v in delivery.data["values"]}
    check(values.get("Paket") == "Premium" and values.get("Zustimmung") == "Ja", "option values reported")
    check(values.get("Unterzeichnet am") not in (None, "", "{{date}}"), "datenow filled with the signing date")
    check(
        all(is_pdf(fetch_bytes(doc["url"]).body) for doc in delivery.data["documents"]),
        "document with all field types is generated as PDF",
    )


def test_signature_verifier_rejects_tampering() -> None:
    step("signature verifier sanity check")
    delivery = deliveries()[0]
    tampered = Delivery(
        delivery.event_type,
        delivery.data,
        delivery.payload,
        delivery.headers,
        delivery.raw + b" ",
        delivery.received_at,
    )
    check(not signature_valid(tampered, HMAC_SECRET), "a modified body fails verification")
    check(not signature_valid(delivery, HMAC_SECRET + "x"), "a wrong secret fails verification")


def write_outputs() -> None:
    if not OUT_DIR:
        return
    redacted = {WEBHOOK_SECRET_HEADER, SIGNATURE_HEADER}
    records = [
        {
            "event_type": d.event_type,
            "headers": {k: ("<redacted>" if k in redacted else v) for k, v in sorted(d.headers.items())},
            "payload": d.payload,
        }
        for d in deliveries()
    ]
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "deliveries.json"), "w", encoding="utf-8") as handle:
        json.dump(records, handle, indent=2, ensure_ascii=False)
    print(f"\nwrote {len(records)} webhook deliveries to {OUT_DIR}/deliveries.json", flush=True)


def main() -> int:
    started = time.monotonic()
    try:
        wait_for_app()
        test_authentication()
        test_validation_errors()
        template = test_create_template()
        test_get_template(template)
        submitters = test_submission(template)
        test_signing_page(submitters[0])
        test_completion_and_webhooks(template, submitters)
        test_declined(template)
        test_expired(template)
        test_field_types()
        test_signature_verifier_rejects_tampering()
        step("all deliveries carry valid signatures")
        for delivery in deliveries():
            check(signature_valid(delivery, HMAC_SECRET), f"{delivery.event_type}: signature valid")
    except AssertionError as error:
        print(f"\nE2E FAILED after {check.count} checks: {error}", flush=True)
        write_outputs()
        return 1
    write_outputs()
    print(f"\nE2E PASSED: {check.count} checks in {time.monotonic() - started:.0f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
