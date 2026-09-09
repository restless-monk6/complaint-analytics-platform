import requests
import csv
import os
import logging
from requests.adapters import HTTPAdapter
from urllib3.util import Retry

BASE_URL = (
    "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/"
)

logger = logging.getLogger(__name__)

_RETRY = Retry(
    total=5,
    backoff_factor=1.0,
    status_forcelist=(429, 500, 502, 503, 504),
    allowed_methods=frozenset({"GET"}),
    respect_retry_after_header=True,
)

_SESSION = requests.Session()
_SESSION.mount("https://", HTTPAdapter(max_retries=_RETRY))

def _params(date_min, date_max, **extra):
    """Build the query params shared by the count call and the CSV download.
    Only presentation options (like format) belong in **extra. Anything that
    changes *which rows* come back must go through both calls, or the row-count
    check compares two different questions.
    """
    params = {
        "date_received_min": date_min,
        "date_received_max": date_max,
        "size": 0,
        "no_aggs": "true",
    }
    params.update(extra)
    return params

def count(date_min, date_max):
    """Return how many complaints the API says are in this window."""
    response = _SESSION.get(BASE_URL, params=_params(date_min, date_max), timeout=30)
    response.raise_for_status()
    data = response.json()
    return data["hits"]["total"]["value"]


def fetch_csv(date_min, date_max, dest):
    """Download this window as CSV to dest. Returns the path written."""

    response = _SESSION.get(
            BASE_URL,
            params=_params(date_min, date_max, format="csv"),
            timeout=120,
    )

    response.raise_for_status()
    logger.info(
        "%s..%s: downloaded %.1f MB",
        date_min,
        date_max,
        len(response.content) / 1e6,
    )
    tmp = f"{dest}.part"
    with open(tmp, "wb") as f:
        f.write(response.content)
    os.replace(tmp, dest)
    return dest

def count_csv_rows(path):
    """Return the number of data rows in a CSV, excluding the header."""
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        next(reader)
        rows = 0
        for _ in reader:
            rows += 1
    return rows

def fetch_window_verified(date_min, date_max, dest):
    """Download a window and prove the file on disk is complete

    Returns the path written. Raises RuntimeError if the rows are missing:
    """
    expected = count(date_min, date_max)
    logger.info("%s..%s: API counts %s complaints", date_min, date_max, expected)
    fetch_csv(date_min, date_max, dest)
    actual = count_csv_rows(dest)

    if actual < expected:
        raise RuntimeError(
            f"Truncated download for {date_min}..{date_max}: "
            f"expected {expected} rows, got {actual}"
        )

    if actual > expected:
        logger.warning(
            "%s..%s: got %s rows, %s more than the count of %s "
            "(late arrivals between the two calls)",
            date_min,
            date_max,
            actual,
            actual - expected,
            expected,
        )

    logger.info("%s..%s: %s rows landed in %s", date_min, date_max, actual, dest)

    return dest


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    print(fetch_window_verified(
        "2026-08-19", "2026-08-19", "data/raw/complaints_2026-08-19.csv"
    ))
