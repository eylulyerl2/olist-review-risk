"""Quick check: can Python read the feature view directly from PostgreSQL?"""

import pandas as pd
from sqlalchemy import text

from db import get_engine


def main() -> None:
    engine = get_engine()

    with engine.connect() as conn:
        version = conn.execute(text("SELECT version()")).scalar_one()
    print("Connected to:", version.split(",")[0])

    counts = pd.read_sql(
        """
        SELECT COUNT(*)            AS total_orders,
               COUNT(is_negative)  AS labeled_orders
        FROM ml.order_features
        """,
        engine,
    )
    print("\nRow counts from ml.order_features:")
    print(counts.to_string(index=False))

    sample = pd.read_sql("SELECT * FROM ml.order_features LIMIT 3", engine)
    print(f"\nFeature columns ({sample.shape[1]}):")
    print(sample.T.to_string())


if __name__ == "__main__":
    main()