"""Shared database connection helper.

Reads the connection settings from the project's .env file, so no
credentials are hard-coded in the source code.
"""

import os
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import Engine, create_engine

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")


def get_engine() -> Engine:
    """Return a SQLAlchemy engine connected to the Olist PostgreSQL database."""
    user = os.getenv("POSTGRES_USER")
    password = os.getenv("POSTGRES_PASSWORD")
    database = os.getenv("POSTGRES_DB")
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5434")

    url = f"postgresql+psycopg://{user}:{password}@{host}:{port}/{database}"
    return create_engine(url)