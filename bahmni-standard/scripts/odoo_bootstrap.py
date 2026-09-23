#!/usr/bin/env python3
"""Configure Odoo for Bahmni after first start (idempotent).

* sets the admin password and the atomfeed (emrsync) service-account password from .env
* creates the Sales Shop, the order types (Drug/Lab/Radiology Order) and their shop mapping;
  without them odoo-connect drops every EMR order with "Order Type - X is not defined"

Env: ODOO_URL, ODOO_DB, ODOO_ADMIN_PASSWORD, ODOO_ATOMFEED_USER, ODOO_ATOMFEED_PASSWORD
Exit code 0 = configured, 1 = failed. Lines starting with [DONE] mean something was changed.
"""
import os
import sys
import xmlrpc.client

URL = os.environ.get("ODOO_URL", "http://127.0.0.1:8069").rstrip("/")
DB = os.environ.get("ODOO_DB", "odoo")
ADMIN_PW = os.environ["ODOO_ADMIN_PASSWORD"]
FEED_USER = os.environ.get("ODOO_ATOMFEED_USER", "emrsync")
FEED_PW = os.environ["ODOO_ATOMFEED_PASSWORD"]
STOCK_ADMIN_PW = "admin"
ORDER_TYPES = ["Drug Order", "Lab Order", "Radiology Order"]

common = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common", allow_none=True)
models = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)
failed = False


def ok(msg):
    print(f"[ OK ] odoo: {msg}")


def done(msg):
    print(f"[DONE] odoo: {msg}")


def fail(msg):
    global failed
    failed = True
    print(f"[FAIL] odoo: {msg}", file=sys.stderr)


def auth(login, password):
    try:
        return common.authenticate(DB, login, password, {}) or None
    except xmlrpc.client.Fault as e:
        fail(f"authenticate({login}) fault: {e.faultString[:200]}")
        return None


class Odoo:
    def __init__(self, uid, password):
        self.uid, self.password = uid, password

    def call(self, model, method, *args, **kwargs):
        return models.execute_kw(DB, self.uid, self.password, model, method, list(args), kwargs)

    def search_read(self, model, domain, fields, **kw):
        return self.call(model, "search_read", domain, fields=fields, **kw)

    def first(self, model, domain, fields):
        rows = self.search_read(model, domain, fields, limit=1)
        return rows[0] if rows else None


# --- admin password -------------------------------------------------------------------------
uid = auth("admin", ADMIN_PW)
if uid:
    ok("admin password is set")
else:
    uid = auth("admin", STOCK_ADMIN_PW)
    if not uid:
        fail("cannot log in as admin with the configured or the stock password")
        sys.exit(1)
    Odoo(uid, STOCK_ADMIN_PW).call("res.users", "change_password", STOCK_ADMIN_PW, ADMIN_PW)
    if not auth("admin", ADMIN_PW):
        fail("admin password change did not take effect")
        sys.exit(1)
    done("admin password changed from the stock default")

odoo = Odoo(uid, ADMIN_PW)

# --- atomfeed service account (used by odoo-connect) -----------------------------------------
if auth(FEED_USER, FEED_PW):
    ok(f"service account '{FEED_USER}' password is set")
else:
    user = odoo.first("res.users", [["login", "=", FEED_USER]], ["id"])
    if not user:
        fail(f"service account '{FEED_USER}' does not exist in Odoo")
    else:
        odoo.call("res.users", "write", [user["id"]], {"password": FEED_PW})
        if auth(FEED_USER, FEED_PW):
            done(f"service account '{FEED_USER}' password set")
        else:
            fail(f"service account '{FEED_USER}' password change did not take effect")

# --- shop + order types ----------------------------------------------------------------------
shop = odoo.first("sale.shop", [], ["id", "name", "location_id"])
if shop:
    ok(f"sales shop '{shop['name']}' exists")
else:
    wh = odoo.first("stock.warehouse", [], ["id", "lot_stock_id"])
    pricelist = odoo.first("product.pricelist", [], ["id"])
    company = odoo.first("res.company", [], ["id"])
    terms = odoo.search_read("account.payment.term", [], ["id", "name"])
    term = next((t for t in terms if "mmediate" in t["name"]), terms[0] if terms else None)
    if not (wh and pricelist and company and term):
        fail("cannot create the sales shop: warehouse/pricelist/company/payment term missing")
        sys.exit(1)
    shop_id = odoo.call("sale.shop", "create", {
        "name": "Main Shop",
        "warehouse_id": wh["id"],
        "location_id": wh["lot_stock_id"][0],
        "pricelist_id": pricelist["id"],
        "company_id": company["id"],
        "payment_default_id": term["id"],
    })
    shop = {"id": shop_id, "name": "Main Shop", "location_id": wh["lot_stock_id"]}
    done("created sales shop 'Main Shop'")

for name in ORDER_TYPES:
    ot = odoo.first("order.type", [["name", "=", name]], ["id"])
    if not ot:
        ot = {"id": odoo.call("order.type", "create", {"name": name})}
        done(f"created order type '{name}'")
    else:
        ok(f"order type '{name}' exists")
    mapping = odoo.first("order.type.shop.map",
                         [["order_type", "=", ot["id"]], ["shop_id", "=", shop["id"]]], ["id"])
    if not mapping:
        odoo.call("order.type.shop.map", "create", {
            "order_type": ot["id"],
            "shop_id": shop["id"],
            "location_id": shop["location_id"][0],
        })
        done(f"mapped '{name}' to shop '{shop['name']}'")

sys.exit(1 if failed else 0)
