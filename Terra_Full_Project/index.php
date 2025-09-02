<?php
$API_ANALYZE = "%%BACKEND_URL%%";
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Car Detection Portal</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
<style>
body { background: #f8f9fa; }
.container { max-width: 800px; margin: 50px auto; }
.preview-img { max-width: 100%; margin-top: 20px; display: block; border-radius: 8px; box-shadow: 0 2px 6px rgba(0,0,0,0.2); }
</style>
</head>
<body>
<div class="container">
  <h3 class="text-center mb-4">📤 Upload Image for Car Detection</h3>

  <form id="uploadForm">
    <div class="mb-3">
      <input class="form-control" type="file" id="fileInput" accept="image/*" required>
    </div>
    <div class="d-grid">
      <button class="btn btn-primary" type="submit">Analyze Image</button>
    </div>
  </form>

  <img id="preview" class="preview-img" style="display:none;">
  <div id="uploadResult" class="mt-4"></div>
</div>

<script>
const API_ANALYZE = "%%BACKEND_URL%%/detect";

document.getElementById("uploadForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const file = document.getElementById("fileInput").files[0];
  if (!file) return;

  // Show preview
  const preview = document.getElementById("preview");
  preview.src = URL.createObjectURL(file);
  preview.style.display = "block";

  const reader = new FileReader();
  reader.readAsDataURL(file);

  reader.onload = async () => {
    const base64Data = reader.result.split(',')[1];

    try {
      const response = await fetch(API_ANALYZE, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ image: base64Data })
      });

      const data = await response.json();

      if (response.ok) {
        // Format labels
        const labels = (data.labels || []).map(
          l => `${l.Name} (${l.Confidence.toFixed(2)}%)`
        ).join(", ") || "No labels detected";

        document.getElementById("uploadResult").innerHTML =
          `<div class="alert alert-success">✅ Labels: ${labels}</div>`;
      } else {
        document.getElementById("uploadResult").innerHTML =
          `<div class="alert alert-danger">❌ Error: ${data.error || 'Unknown error'}</div>`;
      }

    } catch (err) {
      document.getElementById("uploadResult").innerHTML =
        `<div class="alert alert-danger">❌ Fetch error: ${err}</div>`;
    }
  };
});
</script>
</body>
</html>