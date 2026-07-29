"""
Synthetic multi-rail transaction data generator for a BaaS fraud detection project.

Generates realistic-looking ACH, Wire, RTP, and Card transactions across a pool
of synthetic "fintech partner" accounts, with a small labeled fraud rate injected
using rail-specific fraud patterns (not generic random flags):

  ACH   -> models transaction DIRECTION (debit=pull vs credit=push) and three
           fraud typologies: unauthorized debit / account takeover (new payee,
           elevated amount, R10 or R29 return), first-party "friendly fraud"
           (R11), and mule credit-push (new payee, large credit). Return codes
           are direction-gated and realistic -- most rows settle with no return.
  WIRE  -> business email compromise / authorized push payment fraud: new
           beneficiary, urgency flag, amount far above the account's historical
           average, more often international
  RTP   -> real-time account takeover / mule cash-out: new recipient, unusual
           device/IP not seen before on this account, odd hour, large amount
  CARD  -> card-not-present fraud / account testing: AVS/CVV mismatch,
           card-not-present entry mode, cross-border merchant/cardholder mismatch

Output mimics an S3 "bronze" landing structure:
    <output_dir>/bronze/<rail>/<date>.csv
plus a combined file for convenience: <output_dir>/all_transactions.csv

The `is_fraud` and `fraud_type` columns are ground-truth labels for YOUR use in
validating rules/models -- in a real pipeline these would not exist upstream of
your detection logic, only downstream as investigation outcomes.
"""

import argparse
import csv
import glob
import ipaddress
import os
import random
import uuid
from datetime import datetime, timedelta

import numpy as np

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

NUM_PARTNER_BANKS = 20
NUM_ACCOUNTS = 800
NUM_MERCHANTS = 300
CURRENCIES_DOMESTIC = ["USD"]
CURRENCIES_INTL = ["USD", "EUR", "GBP", "MXN", "INR", "PHP"]
ACH_SEC_CODES = ["PPD", "CCD", "WEB", "TEL"]  # PPD/WEB/TEL = consumer, CCD = corporate

# NACHA return reason codes we model, with the direction each one can apply to
# ("debit" = pull from receiver, "credit" = push to receiver, "both" = either).
# A settled ACH has NO return code; returns are a small slice of traffic, and the
# "unauthorized" family (R10/R11/R29) is the fraud signal -- NACHA caps the
# unauthorized-return rate at just 0.5%, so these stay rare and concentrated in fraud.
ACH_RETURN_CODES = {
    "R01": ("Insufficient funds (NSF)", "debit"),
    "R02": ("Account closed", "both"),
    "R03": ("No account / unable to locate account", "both"),
    "R04": ("Invalid account number", "both"),
    "R08": ("Payment stopped", "debit"),
    "R09": ("Uncollected funds", "debit"),
    "R16": ("Account frozen", "both"),
    "R20": ("Non-transaction account", "both"),
    "R23": ("Credit entry refused by receiver", "credit"),
    "R10": ("Customer advises not authorized (unauthorized debit)", "debit"),
    "R11": ("Entry not in accordance with terms of authorization", "debit"),
    "R29": ("Corporate customer advises not authorized", "debit"),
}

# Return-code distributions for NORMAL (non-fraud) traffic, gated by direction.
# ~95%+ settle with no return; the rest are mundane funding/admin returns. Note
# NSF (R01) is a debit-only concept -- you can't have "insufficient funds" on a
# credit you're receiving -- so credits draw from a different, admin-only set.
ACH_NORMAL_DEBIT_RETURNS = {
    None: 0.955, "R01": 0.025, "R02": 0.006, "R03": 0.006,
    "R09": 0.004, "R08": 0.002, "R16": 0.001, "R20": 0.001,
}
ACH_NORMAL_CREDIT_RETURNS = {
    None: 0.975, "R02": 0.008, "R03": 0.008, "R04": 0.005,
    "R23": 0.003, "R16": 0.001,
}
MCC_CODES = [5411, 5812, 5942, 5732, 5691, 4829, 6011, 7995, 5999, 5661]
COUNTRIES = ["US", "CA", "MX", "GB", "NG", "PH", "IN", "CN", "BR", "RU"]
HIGH_RISK_COUNTRIES = {"NG", "RU", "CN"}


def make_partner_banks():
    return [f"PARTNER-{i:03d}" for i in range(1, NUM_PARTNER_BANKS + 1)]


def make_accounts(partner_banks, rng):
    """Each account carries the running profile info needed to compute
    velocity/novelty features (avg amount, known payees, known devices)."""
    accounts = {}
    for i in range(NUM_ACCOUNTS):
        acct_id = f"ACC{i:06d}"
        accounts[acct_id] = {
            "account_id": acct_id,
            "partner_bank_id": rng.choice(partner_banks),
            "account_age_days": int(rng.integers(30, 3650)),
            "avg_amount": float(rng.lognormal(mean=5.5, sigma=0.6)),  # ~ hundreds of dollars
            "known_payees": set(),
            "known_devices": set(),
        }
    return accounts


def make_merchants(rng):
    merchants = []
    for i in range(NUM_MERCHANTS):
        merchants.append({
            "merchant_id": f"MER{i:05d}",
            "mcc_code": int(rng.choice(MCC_CODES)),
            "merchant_country": rng.choice(COUNTRIES, p=_country_weights()),
        })
    return merchants


def _country_weights():
    # Weight US heavily, a long tail of other countries
    weights = np.array([0.70, 0.06, 0.05, 0.04, 0.03, 0.03, 0.03, 0.02, 0.02, 0.02])
    return weights / weights.sum()


def random_timestamp(rng, days_back, odd_hour_bias=False):
    day_offset = int(rng.integers(0, days_back))
    base_day = datetime.now() - timedelta(days=day_offset)
    if odd_hour_bias and rng.random() < 0.6:
        hour = int(rng.choice([0, 1, 2, 3, 4, 23]))
    else:
        # business-hours-weighted normal traffic
        hour = int(np.clip(rng.normal(loc=14, scale=4), 0, 23))
    minute = int(rng.integers(0, 60))
    second = int(rng.integers(0, 60))
    return base_day.replace(hour=hour, minute=minute, second=second, microsecond=0)


def random_ip(rng):
    return str(ipaddress.IPv4Address(int(rng.integers(0, 2**32 - 1))))


def _weighted_choice(rng, dist):
    """Sample a key from a {value: probability} dict (probs are normalized, so
    they need not sum to exactly 1). Handles a None key for 'no return code'."""
    keys = list(dist.keys())
    probs = np.array(list(dist.values()), dtype=float)
    probs = probs / probs.sum()
    return keys[int(rng.choice(len(keys), p=probs))]


# ---------------------------------------------------------------------------
# Rail generators
# ---------------------------------------------------------------------------

def gen_ach(n, fraud_rate, accounts, days_back, rng):
    """ACH models transaction DIRECTION (debit = pull, credit = push), because
    direction drives which fraud typology and which return codes are even
    possible. Three fraud flavors are injected:
      - unauthorized_debit : account takeover -- new payee, elevated amount,
                             R10 (consumer) or R29 (corporate/CCD) return
      - friendly_fraud     : first-party dispute -- looks legit, R11 return
      - mule_credit_push   : push to a brand-new payee (mule), large credit,
                             typically settles (no return)
    """
    rows = []
    acct_ids = list(accounts.keys())
    n_fraud = int(n * fraud_rate)

    # Split the fraud rows across the three typologies (60 / 20 / 20).
    def _fraud_subtype(k):
        r = k / max(n_fraud, 1)
        if r < 0.60:
            return "unauthorized_debit"
        if r < 0.80:
            return "friendly_fraud"
        return "mule_credit_push"

    for i in range(n):
        is_fraud = i < n_fraud
        originator_id = rng.choice(acct_ids)
        originator = accounts[originator_id]

        if is_fraud and _fraud_subtype(i) == "unauthorized_debit":
            # Account takeover: unauthorized PULL to a payee never used before,
            # amount well above the account's norm. R29 if corporate SEC code, else R10.
            direction = "debit"
            beneficiary_id = rng.choice(acct_ids)
            is_new_payee = True
            amount = round(originator["avg_amount"] * rng.uniform(3, 9), 2)
            sec_code = rng.choice(["PPD", "WEB", "TEL", "CCD"], p=[0.4, 0.3, 0.1, 0.2])
            return_code = "R29" if sec_code == "CCD" else "R10"
            fraud_type = "ach_unauthorized_debit"
        elif is_fraud and _fraud_subtype(i) == "friendly_fraud":
            # First-party ("friendly") fraud: a debit the customer authorized but
            # later disputes -- often a payee they DID use. R11 = terms-of-auth dispute.
            direction = "debit"
            if originator["known_payees"] and rng.random() < 0.5:
                beneficiary_id = rng.choice(list(originator["known_payees"]))
                is_new_payee = False
            else:
                beneficiary_id = rng.choice(acct_ids)
                is_new_payee = True
            amount = round(max(1.0, rng.normal(originator["avg_amount"] * 1.5, originator["avg_amount"] * 0.4)), 2)
            sec_code = rng.choice(["PPD", "WEB", "TEL"], p=[0.5, 0.4, 0.1])
            return_code = "R11"
            fraud_type = "ach_friendly_fraud"
        elif is_fraud:
            # Mule credit-push: large PUSH to a brand-new payee (the mule). This
            # settles cleanly -- the signal is new payee + large credit, not a return.
            direction = "credit"
            beneficiary_id = rng.choice(acct_ids)
            is_new_payee = True
            amount = round(originator["avg_amount"] * rng.uniform(3, 8), 2)
            sec_code = rng.choice(["PPD", "CCD"], p=[0.6, 0.4])
            return_code = None
            fraud_type = "ach_mule_credit_push"
        else:
            # Normal traffic: ~60% debits (bill pay) / 40% credits (payroll, vendor).
            direction = "debit" if rng.random() < 0.6 else "credit"
            if originator["known_payees"] and rng.random() < 0.65:
                beneficiary_id = rng.choice(list(originator["known_payees"]))
                is_new_payee = False
            else:
                beneficiary_id = rng.choice(acct_ids)
                is_new_payee = True
            amount = round(max(1.0, rng.normal(originator["avg_amount"], originator["avg_amount"] * 0.3)), 2)
            if direction == "credit":
                # WEB/TEL are debit-only SEC codes; credits use PPD (payroll) or CCD.
                sec_code = rng.choice(["PPD", "CCD"], p=[0.7, 0.3])
                return_code = _weighted_choice(rng, ACH_NORMAL_CREDIT_RETURNS)
            else:
                sec_code = rng.choice(["PPD", "CCD", "WEB", "TEL"], p=[0.45, 0.2, 0.25, 0.1])
                return_code = _weighted_choice(rng, ACH_NORMAL_DEBIT_RETURNS)
            fraud_type = None

        originator["known_payees"].add(beneficiary_id)
        ts = random_timestamp(rng, days_back)

        rows.append({
            "transaction_id": str(uuid.uuid4()),
            "rail_type": "ACH",
            "partner_bank_id": originator["partner_bank_id"],
            "originator_account_id": originator_id,
            "beneficiary_account_id": beneficiary_id,
            "direction": direction,
            "amount": amount,
            "currency": "USD",
            "timestamp": ts.isoformat(),
            "sec_code": sec_code,
            "return_code": return_code,
            "is_new_payee": is_new_payee,
            "originator_account_age_days": originator["account_age_days"],
            "is_fraud": int(is_fraud),
            "fraud_type": fraud_type,
        })
    return rows


def gen_wire(n, fraud_rate, accounts, days_back, rng):
    rows = []
    acct_ids = list(accounts.keys())
    n_fraud = int(n * fraud_rate)
    for i in range(n):
        is_fraud = i < n_fraud
        originator_id = rng.choice(acct_ids)
        originator = accounts[originator_id]
        beneficiary_id = f"EXT-{rng.integers(100000, 999999)}"  # wires often go external
        beneficiary_bank_swift = f"SWFT{rng.integers(1000, 9999)}XXX"

        if is_fraud:
            # BEC / authorized push payment fraud: brand-new beneficiary, urgent,
            # amount far above historical norm, more often international.
            is_new_beneficiary = True
            urgency_flag = True
            amount_vs_avg_ratio = round(rng.uniform(4, 12), 2)
            amount = round(originator["avg_amount"] * amount_vs_avg_ratio, 2)
            wire_type = "international" if rng.random() < 0.6 else "domestic"
            beneficiary_account_age_days = int(rng.integers(0, 10))  # freshly opened mule account
            fraud_type = "wire_bec_app_fraud"
        else:
            is_new_beneficiary = rng.random() < 0.15
            urgency_flag = rng.random() < 0.05
            amount_vs_avg_ratio = round(rng.uniform(0.5, 2.0), 2)
            amount = round(originator["avg_amount"] * amount_vs_avg_ratio, 2)
            wire_type = "international" if rng.random() < 0.15 else "domestic"
            beneficiary_account_age_days = int(rng.integers(30, 3650))
            fraud_type = None

        ts = random_timestamp(rng, days_back)
        rows.append({
            "transaction_id": str(uuid.uuid4()),
            "rail_type": "WIRE",
            "partner_bank_id": originator["partner_bank_id"],
            "originator_account_id": originator_id,
            "beneficiary_account_id": beneficiary_id,
            "beneficiary_bank_swift": beneficiary_bank_swift,
            "amount": amount,
            "currency": rng.choice(CURRENCIES_INTL) if wire_type == "international" else "USD",
            "timestamp": ts.isoformat(),
            "wire_type": wire_type,
            "is_new_beneficiary": is_new_beneficiary,
            "urgency_flag": urgency_flag,
            "amount_vs_avg_ratio": amount_vs_avg_ratio,
            "beneficiary_account_age_days": beneficiary_account_age_days,
            "is_fraud": int(is_fraud),
            "fraud_type": fraud_type,
        })
    return rows


def gen_rtp(n, fraud_rate, accounts, days_back, rng):
    rows = []
    acct_ids = list(accounts.keys())
    n_fraud = int(n * fraud_rate)
    for i in range(n):
        is_fraud = i < n_fraud
        originator_id = rng.choice(acct_ids)
        originator = accounts[originator_id]
        beneficiary_id = rng.choice(acct_ids)

        if is_fraud:
            # Real-time account takeover / mule cash-out: device/IP never seen on
            # this account, new recipient, odd hour, large amount, irrevocable rail.
            device_id = f"DEV-{uuid.uuid4().hex[:8]}"
            is_new_recipient = True
            amount = round(originator["avg_amount"] * rng.uniform(3, 8), 2)
            ts = random_timestamp(rng, days_back, odd_hour_bias=True)
            fraud_type = "rtp_takeover_mule_cashout"
        else:
            if originator["known_devices"] and rng.random() < 0.8:
                device_id = rng.choice(list(originator["known_devices"]))
            else:
                device_id = f"DEV-{uuid.uuid4().hex[:8]}"
            is_new_recipient = rng.random() < 0.2
            amount = round(max(1.0, rng.normal(originator["avg_amount"] * 0.6, originator["avg_amount"] * 0.2)), 2)
            ts = random_timestamp(rng, days_back)
            fraud_type = None

        originator["known_devices"].add(device_id)
        rows.append({
            "transaction_id": str(uuid.uuid4()),
            "rail_type": "RTP",
            "partner_bank_id": originator["partner_bank_id"],
            "originator_account_id": originator_id,
            "beneficiary_account_id": beneficiary_id,
            "amount": amount,
            "currency": "USD",
            "timestamp": ts.isoformat(),
            "device_id": device_id,
            "ip_address": random_ip(rng),
            "is_new_recipient": is_new_recipient,
            "hour_of_day": ts.hour,
            "is_fraud": int(is_fraud),
            "fraud_type": fraud_type,
        })
    return rows


def gen_card(n, fraud_rate, accounts, merchants, days_back, rng):
    rows = []
    acct_ids = list(accounts.keys())
    n_fraud = int(n * fraud_rate)
    for i in range(n):
        is_fraud = i < n_fraud
        originator_id = rng.choice(acct_ids)
        originator = accounts[originator_id]
        merchant = merchants[rng.integers(0, len(merchants))]
        card_id = f"CARD-{uuid.uuid4().hex[:10]}"
        cardholder_country = "US"  # assume US-issued BaaS cards by default

        if is_fraud:
            # Card-not-present fraud / account testing: mismatch flags, CNP entry,
            # cross-border merchant vs cardholder, often a small "testing" amount.
            entry_mode = "card_not_present"
            is_card_present = False
            avs_result = "mismatch"
            cvv_result = rng.choice(["mismatch", "not_provided"])
            amount = round(rng.choice([rng.uniform(1, 5), originator["avg_amount"] * rng.uniform(2, 6)]), 2)
            merchant_country = rng.choice(list(set(COUNTRIES) - {"US"}))
            fraud_type = "card_cnp_testing_or_fraud"
        else:
            entry_mode = rng.choice(["chip", "swipe", "contactless", "card_not_present"],
                                     p=[0.45, 0.10, 0.30, 0.15])
            is_card_present = entry_mode != "card_not_present"
            avs_result = "match" if rng.random() < 0.92 else "mismatch"
            cvv_result = "match" if rng.random() < 0.95 else "mismatch"
            amount = round(max(1.0, rng.normal(originator["avg_amount"] * 0.2, originator["avg_amount"] * 0.1)), 2)
            merchant_country = merchant["merchant_country"]
            fraud_type = None

        ts = random_timestamp(rng, days_back, odd_hour_bias=is_fraud)
        rows.append({
            "transaction_id": str(uuid.uuid4()),
            "rail_type": "CARD",
            "partner_bank_id": originator["partner_bank_id"],
            "originator_account_id": originator_id,
            "card_id": card_id,
            "merchant_id": merchant["merchant_id"],
            "mcc_code": merchant["mcc_code"],
            "amount": amount,
            "currency": "USD",
            "timestamp": ts.isoformat(),
            "entry_mode": entry_mode,
            "is_card_present": is_card_present,
            "avs_result": avs_result,
            "cvv_result": cvv_result,
            "merchant_country": merchant_country,
            "cardholder_country": cardholder_country,
            "is_fraud": int(is_fraud),
            "fraud_type": fraud_type,
        })
    return rows


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def write_rail_csv(rows, rail_name, output_dir):
    """Writes one CSV per rail, and also splits by date into a bronze/<rail>/<date>.csv
    structure so it mirrors what your S3 landing zone would actually look like."""
    if not rows:
        return
    fieldnames = list(rows[0].keys())

    combined_path = os.path.join(output_dir, f"{rail_name.lower()}_transactions.csv")
    with open(combined_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    by_date = {}
    for row in rows:
        date_key = row["timestamp"][:10]
        by_date.setdefault(date_key, []).append(row)

    rail_dir = os.path.join(output_dir, "bronze", rail_name.lower())
    os.makedirs(rail_dir, exist_ok=True)
    # Clear stale date-files from previous runs so this rail's bronze split always
    # reflects exactly the current run. Without this, runs with different seeds/date
    # ranges leave orphan files behind and downstream loads (S3 -> Snowflake) over-count.
    for stale in glob.glob(os.path.join(rail_dir, "*.csv")):
        os.remove(stale)
    for date_key, date_rows in by_date.items():
        path = os.path.join(rail_dir, f"{date_key}.csv")
        with open(path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(date_rows)


def print_summary(rail_rows):
    print("\n=== Generation summary ===")
    total = 0
    total_fraud = 0
    for rail, rows in rail_rows.items():
        n = len(rows)
        n_fraud = sum(r["is_fraud"] for r in rows)
        total += n
        total_fraud += n_fraud
        pct = (n_fraud / n * 100) if n else 0
        print(f"{rail:6s}: {n:6d} transactions | {n_fraud:4d} fraud ({pct:.1f}%)")
    print(f"{'TOTAL':6s}: {total:6d} transactions | {total_fraud:4d} fraud "
          f"({(total_fraud/total*100 if total else 0):.1f}%)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate synthetic multi-rail BaaS transaction data.")
    parser.add_argument("--num-per-rail", type=int, default=5000,
                         help="Number of transactions to generate per payment rail (default: 5000)")
    parser.add_argument("--fraud-rate", type=float, default=0.02,
                         help="Fraction of transactions per rail that are fraudulent (default: 0.02)")
    parser.add_argument("--days", type=int, default=30,
                         help="Spread transactions over this many past days (default: 30)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed for reproducibility")
    parser.add_argument("--output-dir", type=str, default="./data",
                         help="Output directory (default: ./data)")
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    random.seed(args.seed)

    os.makedirs(args.output_dir, exist_ok=True)

    partner_banks = make_partner_banks()
    accounts = make_accounts(partner_banks, rng)
    merchants = make_merchants(rng)

    rail_rows = {
        "ACH": gen_ach(args.num_per_rail, args.fraud_rate, accounts, args.days, rng),
        "WIRE": gen_wire(args.num_per_rail, args.fraud_rate, accounts, args.days, rng),
        "RTP": gen_rtp(args.num_per_rail, args.fraud_rate, accounts, args.days, rng),
        "CARD": gen_card(args.num_per_rail, args.fraud_rate, accounts, merchants, args.days, rng),
    }

    for rail, rows in rail_rows.items():
        write_rail_csv(rows, rail, args.output_dir)

    print_summary(rail_rows)
    print(f"\nFiles written to: {os.path.abspath(args.output_dir)}")
    print("  - <rail>_transactions.csv        (one flat file per rail)")
    print("  - bronze/<rail>/<date>.csv        (mirrors an S3 bronze landing structure)")


if __name__ == "__main__":
    main()
