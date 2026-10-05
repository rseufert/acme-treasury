#!/usr/bin/env python3
"""The world the forecast is checked against: suppliers that bill, customers
that owe, and a payment run every morning.

The run is mock-acme's `payment_run`, unchanged, so what the
forecast is held to is the chain the mocks already document, not one written
to agree with it. Each command prints JSON.

    world.py SAP BANK reset
    world.py SAP BANK payable SUPPLIER REFERENCE GROSS DUE [BLOCK]
    world.py SAP BANK receivable CUSTOMER AMOUNT DUE
    world.py SAP BANK morning
    world.py SAP BANK statements
    world.py SAP BANK run
"""
import datetime
import json
import sys

from mockacme.bank_messages import call
from mockacme.payment_run import ODATA, PaymentRun, Run, SapSession

ACME = {"name": "ACME Corporation", "iban": "NL41MOCK0000000001", "bic": "MOCKNL2A"}


def control(base, method, path):
    status, raw = call(base, method, path)
    if status >= 300:
        raise SystemExit("%s %s%s answered %d" % (method, base, path, status))
    return json.loads(raw or b"null")


def payable(sap, supplier, reference, gross, due, block=""):
    """An inbound INVOIC payable at once, so the due date is its date."""
    session = SapSession(sap)
    posted = json.loads(session.write("POST", "/sap/bc/idoc/idoc_xml", """<?xml version="1.0"?>
<INVOIC02><IDOC BEGIN="1">
<EDI_DC40 SEGMENT="1"><IDOCTYP>INVOIC02</IDOCTYP><MESTYP>INVOIC</MESTYP></EDI_DC40>
<E1EDK01 SEGMENT="1"><CURCY>EUR</CURCY><ZTERM>0001</ZTERM></E1EDK01>
<E1EDKA1 SEGMENT="1"><PARVW>LF</PARVW><PARTN>%s</PARTN></E1EDKA1>
<E1EDK02 SEGMENT="1"><QUALF>009</QUALF><BELNR>%s</BELNR></E1EDK02>
<E1EDK03 SEGMENT="1"><IDDAT>026</IDDAT><DATUM>%s</DATUM></E1EDK03>
<E1EDS01 SEGMENT="1"><SUMID>010</SUMID><SUMME>%s</SUMME></E1EDS01>
</IDOC></INVOIC02>""" % (supplier, reference, due.replace("-", ""), gross),
        "application/xml"))["APPLIED"][0]
    if block:
        session.write("PATCH", ODATA + "/API_SUPPLIERINVOICE_PROCESS_SRV/A_SupplierInvoice"
                      "(SupplierInvoice='%s',FiscalYear='%s')"
                      % (posted["SUPPLIERINVOICE"], posted["FISCALYEAR"]),
                      json.dumps({"PaymentBlockingReason": block}), "application/json")
    return posted


def receivable(sap, customer, amount, due):
    """A customer line due on `due`, posted as an accounting document."""
    out = json.loads(SapSession(sap).write("POST", "/sap/bc/rfc/BAPI_ACC_DOCUMENT_POST", json.dumps({
        "DOCUMENTHEADER": {"COMP_CODE": "1710", "DOC_TYPE": "DR", "DOC_DATE": due, "PSTNG_DATE": due},
        "ACCOUNTRECEIVABLE": [{"ITEMNO_ACC": "1", "CUSTOMER": customer, "PMNTTRMS": "0001",
                               "BLINE_DATE": due, "ITEM_TEXT": "Invoice"}],
        "ACCOUNTGL": [{"ITEMNO_ACC": "2", "GL_ACCOUNT": "0000800000", "ITEM_TEXT": "Revenue"}],
        "CURRENCYAMOUNT": [{"ITEMNO_ACC": "1", "CURRENCY": "EUR", "AMT_DOCCUR": amount},
                           {"ITEMNO_ACC": "2", "CURRENCY": "EUR", "AMT_DOCCUR": "-" + amount}],
    }), "application/json"))
    if out["RETURN"][0]["TYPE"] != "S":
        raise SystemExit("SAP refused the receivable: %s" % out["RETURN"])
    return {"ACCOUNTINGDOCUMENT": out["OBJ_KEY"][:10]}


def today(bank):
    clock = control(bank, "GET", "/_mock/state")["clock"]
    return datetime.date.fromisoformat(clock["date"]), clock["isBusinessDay"]


def statements(sap, bank):
    """Post the statements the bank has issued since the last time."""
    day, _ = today(bank)
    before = Run(day, "pre")
    PaymentRun(sap, bank, ACME).reconcile(before)
    return {"day": day.isoformat(), "items": [], "problems": list(before.problems)}


def run(sap, bank):
    """Pay what is due today. No run on a day the bank does not settle."""
    day, settles = today(bank)
    items, problems = [], []
    if settles:
        done = PaymentRun(sap, bank, ACME).run(day, "R1")
        problems = list(done.problems)
        items = [{"reference": i.reference, "status": i.status, "reason": i.reason,
                  "amount": i.amount} for i in done.items]
    return {"day": day.isoformat(), "items": items, "problems": problems}


def morning(sap, bank):
    """Post the statements the bank has issued, then pay what is due today.

    Statements first, so an invoice whose payment came back yesterday is open
    again before today's selection. A payment schedule is applied between the
    two, which is why each is also a command of its own.
    """
    posted, paid = statements(sap, bank), run(sap, bank)
    return {"day": paid["day"], "items": paid["items"],
            "problems": posted["problems"] + paid["problems"]}


def main(argv):
    sap, bank, command, rest = argv[1], argv[2], argv[3], argv[4:]
    if command == "reset":
        out = [control(sap, "POST", "/_mock/reset"), control(bank, "POST", "/_mock/reset")]
    elif command == "payable":
        out = payable(sap, *rest)
    elif command == "receivable":
        out = receivable(sap, *rest)
    elif command == "statements":
        out = statements(sap, bank)
    elif command == "run":
        out = run(sap, bank)
    elif command == "morning":
        out = morning(sap, bank)
    else:
        raise SystemExit("unknown command %r" % command)
    print(json.dumps(out))


if __name__ == "__main__":
    main(sys.argv)
