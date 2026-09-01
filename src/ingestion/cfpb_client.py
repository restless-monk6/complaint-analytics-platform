import requests
import csv

BASE_URL = (
    "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/"
)


def count(date_min, date_max):
    """Return how many complaints..."""
    params = {
        "date_received_min": date_min,
        "date_received_max": date_max,
        "size": 0,
        "no_aggs": "true",
    }

    response = requests.get(BASE_URL, params=params, timeout=30)
    response.raise_for_status()
    data = response.json()
    return data["hits"]["total"]["value"]

def fetch_csv(date_min, date_max, dest):
    """Download this window as CSV to dest. Returns the path written."""
    params = {
        "date_received_min": date_min,
        "date_received_max": date_max,
        "size": 0,
        "no_aggs": "true",
        "format": "csv",
    }
    response = requests.get(BASE_URL, params=params, timeout=120)
    response.raise_for_status()
    with open(dest, "wb") as f: 
        f.write(response.content)
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
    fetch_csv(date_min, date_max, dest)
    actual = count_csv_rows(dest)

    if actual < expected:
        raise RuntimeError(
            f"Truncated download for {date_min}..{date_max}: "
            f"expected {expected} rows, got {actual}"
        )
    
    if actual > expected:
        print(
            f"{date_min}..{date_max}: got {actual} rows, "
            f"{actual - expected} more than the count of {expected} "
            f"(late arrivals between the two calls)"
        )
    
    return dest

#if __name__ == "__main__":
#    print(fetch_window_verified("2026-08-19", "2026-08-19","data/raw/complaints_2026-08-19.csv"))
if __name__ == "__main__":
    print(count_csv_rows("data/raw/cfpb_sample.csv"))          # 55052
    print(count("2026-08-18", "2026-08-20"))                   # ~86937
