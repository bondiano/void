# FastAPI+uvicorn calibration baseline (SPEC §8.3, ADR-0014) — the
# Python interpreter class void competes in. Serves both bench shapes:
# GET / plaintext and POST /echo JSON echo through pydantic models —
# the closest analogue of B1's parse+validate+serialize.
#
#   python3 -m pip install -r requirements.txt
#   PORT=8181 python3 -m uvicorn app:app --host 127.0.0.1 --port 8181 --log-level warning
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel


class Address(BaseModel):
    street: str
    city: str
    zip: str
    country: str


class Customer(BaseModel):
    name: str
    email: str
    address: Address


class Item(BaseModel):
    sku: str
    name: str
    qty: int
    price: float


class Order(BaseModel):
    id: int
    currency: str
    customer: Customer
    items: list[Item]
    note: str | None = None


app = FastAPI()


@app.get("/", response_class=PlainTextResponse)
def hello() -> str:
    return "Hello, World!"


@app.post("/echo")
def echo(order: Order) -> Order:
    return order
