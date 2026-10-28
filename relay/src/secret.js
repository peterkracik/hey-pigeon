// Read the APNs .p8 from Secret Manager at runtime. The secret is created
// empty by Terraform and filled by hand (`gcloud secrets versions add`), so
// the key never passes through Terraform state or a deploy-time mount.

import { SecretManagerServiceClient } from "@google-cloud/secret-manager";

export async function loadSecret(secretName, client = new SecretManagerServiceClient()) {
  const name = secretName.includes("/versions/") ? secretName : `${secretName}/versions/latest`;
  const [version] = await client.accessSecretVersion({ name });
  const data = version?.payload?.data;
  if (!data) throw new Error(`secret ${secretName} has no payload`);
  return Buffer.from(data).toString("utf8");
}
