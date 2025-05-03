from flask import Flask, request, jsonify, render_template
import pandas as pd
from sklearn.tree import DecisionTreeClassifier
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score
import pymongo
import os
import xml.etree.ElementTree as ET
import json
app = Flask(__name__)

# MongoDB connection
client = pymongo.MongoClient("mongodb://localhost:27017")
db = client["official_crime"]
collection = db["test101"]

# Function to Convert XML to DataFrame
def convert_xml_to_csv(file):
    """Convert XML crime data to Pandas DataFrame."""
    tree = ET.parse(file)
    root = tree.getroot()

    data = []
    
    for record in root.findall("row"):  # Extracting each crime record
        entry = {child.tag: child.text for child in record}
        data.append(entry)

    # Convert to Pandas DataFrame
    df = pd.DataFrame(data)

    # Convert numeric columns to appropriate data types
    numeric_cols = ["Latitude", "Longitude", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE"]
    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")  # Convert to numeric, handling errors

    return df

# Function to Convert JSON to DataFrame
def convert_json_to_csv(file):
    """Convert JSON crime data to Pandas DataFrame."""
    with open(file, "r", encoding="utf-8") as f:
        data = json.load(f)  # Load JSON file

    # Remove MongoDB _id field
    for record in data:
        if "_id" in record:
            del record["_id"]

    # Convert to DataFrame
    df = pd.DataFrame(data)

    # Convert numeric columns to appropriate data types
    numeric_cols = ["Latitude", "Longitude", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE"]
    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")  # Convert to numeric, handling errors

    return df

@app.route("/")
def home():
    return render_template("index.html")

@app.route("/initial-upload", methods=["POST"])
def initial_upload():
    if "file" not in request.files:
        return jsonify({"error": "No file part in the request"}), 400

    file = request.files["file"]
    if file.filename == "":
        return jsonify({"error": "No selected file"}), 400

    ext = os.path.splitext(file.filename)[1].lower()

    try:
        # Convert XML to DataFrame if needed
        if ext == ".xml":
            temp_path = "temp.xml"
            file.save(temp_path)
            df = convert_xml_to_csv(temp_path)
            os.remove(temp_path)
        elif ext == ".json":
            temp_path = "temp.json"
            file.save(temp_path)
            df = convert_json_to_csv(temp_path)  # Use updated function
            os.remove(temp_path)
        elif ext == ".csv":
            df = pd.read_csv(file)
        else:
            return jsonify({"error": "Unsupported file format. Upload CSV, XML, or JSON"}), 400

        df.drop_duplicates(inplace=True)
        # Ensure required columns exist
        required_cols = {"Latitude", "Longitude", "TYPE"}
        if not required_cols.issubset(df.columns):
            return jsonify({"error": f"Missing required columns: {required_cols - set(df.columns)}"}), 400

        # Create latitude-longitude grid
        lat_grid_size = 0.01
        lon_grid_size = 0.01
        df["lat_grid"] = (df["Latitude"] // lat_grid_size).astype(int)
        df["lon_grid"] = (df["Longitude"] // lon_grid_size).astype(int)
        df["cluster"] = df["lat_grid"].astype(str) + "_" + df["lon_grid"].astype(str)

        # Prepare data for models
        X = df[["Latitude", "Longitude", "lat_grid", "lon_grid"]]
        y = df["TYPE"]

        # Train models
        X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)
        tree_model = DecisionTreeClassifier(random_state=42)
        rf_model = RandomForestClassifier(random_state=42)
        tree_model.fit(X_train, y_train)
        rf_model.fit(X_train, y_train)

        # Select the best model
        tree_accuracy = accuracy_score(y_test, tree_model.predict(X_test))
        rf_accuracy = accuracy_score(y_test, rf_model.predict(X_test))
        best_model = tree_model if tree_accuracy > rf_accuracy else rf_model

        # Add predictions to the data
        df["predicted_type"] = best_model.predict(X)

        # Insert into MongoDB
        records = df.to_dict(orient="records")
        collection.insert_many(records)

        return render_template("success.html", message="Initial upload completed."), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/update-upload", methods=["POST"])
def update_upload():
    if "file" not in request.files:
        return jsonify({"error": "No file part in the request"}), 400

    file = request.files["file"]
    if file.filename == "":
        return jsonify({"error": "No selected file"}), 400

    ext = os.path.splitext(file.filename)[1].lower()

    try:
        # Convert file to DataFrame
        if ext == ".xml":
            temp_path = "temp.xml"
            file.save(temp_path)
            df = convert_xml_to_csv(temp_path)
            os.remove(temp_path)
        elif ext == ".json":
            temp_path = "temp.json"
            file.save(temp_path)
            df = convert_json_to_csv(temp_path)
            os.remove(temp_path)
        elif ext == ".csv":
            df = pd.read_csv(file)
        else:
            return jsonify({"error": "Unsupported file format. Upload CSV, XML, or JSON"}), 400

        # Ensure required columns exist
        required_cols = {"Latitude", "Longitude", "TYPE"}
        if not required_cols.issubset(df.columns):
            return jsonify({"error": f"Missing required columns: {required_cols - set(df.columns)}"}), 400

        # Drop NaN values in required columns
        df.dropna(subset=["Latitude", "Longitude", "TYPE"], inplace=True)

        # Create latitude-longitude grid
        lat_grid_size = 0.01
        lon_grid_size = 0.01
        df["lat_grid"] = (df["Latitude"] // lat_grid_size).astype(int)
        df["lon_grid"] = (df["Longitude"] // lon_grid_size).astype(int)
        df["cluster"] = df["lat_grid"].astype(str) + "_" + df["lon_grid"].astype(str)

        # Load existing data from MongoDB
        existing_data = pd.DataFrame(list(collection.find({}, {"_id": 0})))

        # Fill missing values before merging
        existing_data.fillna("", inplace=True)
        df.fillna("", inplace=True)

        # 🔧 Ensure numeric conversion to prevent errors with model training
        numeric_cols = ["Latitude", "Longitude", "lat_grid", "lon_grid"]
        for col in numeric_cols:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors="coerce")
            if col in existing_data.columns:
                existing_data[col] = pd.to_numeric(existing_data[col], errors="coerce")

        # Merge with existing data
        combined_data = pd.concat([existing_data, df], ignore_index=True)

        # 🔧 Drop any remaining rows with invalid data for modeling
        combined_data.dropna(subset=["Latitude", "Longitude", "lat_grid", "lon_grid", "TYPE"], inplace=True)

        # Process clusters
        clusters = combined_data["cluster"].dropna().unique()  # Drop NaN clusters

        for cluster in clusters:
            cluster_data = combined_data[combined_data["cluster"] == cluster]

            if cluster_data.empty:
                continue

            X = cluster_data[["Latitude", "Longitude", "lat_grid", "lon_grid"]]
            y = cluster_data["TYPE"]

            if y.nunique() > 1:
                X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)
                tree_model = DecisionTreeClassifier(random_state=42)
                tree_model.fit(X_train, y_train)
                cluster_data["predicted_type"] = tree_model.predict(X)
            else:
                cluster_data["predicted_type"] = y.iloc[0]  # Assign directly

            # Update MongoDB
            for _, row in cluster_data.iterrows():
                collection.update_one(
                    {"Longitude": row["Longitude"], "Latitude": row["Latitude"], "cluster": row["cluster"]},
                    {"$set": {"predicted_type": row["predicted_type"]}},
                    upsert=True
                )

        return render_template("success.html", message="Update upload completed."), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(debug=True, port=5000)
