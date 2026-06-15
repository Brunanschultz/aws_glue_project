import pandas as pd

bucket_source = "s3://learning-aws-etl-bruna-novais-2026/extract"
bucket_destination = "s3://learning-aws-etl-bruna-novais-2026/load"

df = pd.read_csv(f"{bucket_source}/wc_top_scorers.csv")

df = df.groupby(["player","country"])["goals"].sum().sort_values(ascending=False)

df.to_csv(f"{bucket_destination}/wc_top_scorers_grouped.csv")
print(f"Salvo no S3: {bucket_destination}/wc_top_scorers_grouped.csv")