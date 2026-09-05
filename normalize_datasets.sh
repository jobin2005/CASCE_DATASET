chmod +x normalize_datasets.py
./normalize_datasets.py dataset_dev/run_1 --drop-noise
./normalize_datasets.py dataset_dev/run_2 --drop-noise
./normalize_datasets.py dataset_dev/run_3 --drop-noise
./normalize_datasets.py dataset_test/run_1 --drop-noise
./normalize_datasets.py dataset_test/run_2 --drop-noise
./normalize_datasets.py dataset_test/run_3 --drop-noise