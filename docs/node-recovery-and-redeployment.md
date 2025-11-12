<h1>Linode HA NAT Gateway — Node Recovery and Redeployment Guide</h1>

<p>
This guide explains how to <strong>recover or rebuild any failed NAT node</strong> in your Linode High Availability NAT Gateway cluster without disrupting live traffic.
It ensures full restoration of state synchronization, IP sharing, and failover behavior.
</p>

<hr>

<h2>1️⃣ Understanding the Failure Impact</h2>

<p>If a NAT node (e.g., <code>nat1-a</code>) becomes unreachable or unrecoverable due to hardware failure or accidental deletion:</p>

<table>
  <tr><th>Component</th><th>Status During Failure</th><th>Notes</th></tr>
  <tr><td><strong>Traffic Flow</strong></td><td>✅ Continues via backup node (<code>nat1-b</code>)</td><td>Keepalived promotes backup → MASTER automatically</td></tr>
  <tr><td><strong>Floating IP (FIP)</strong></td><td>✅ Still bound to backup node</td><td>Remains active until peer recovery</td></tr>
  <tr><td><strong>VLAN Interface</strong></td><td>✅ Active on backup</td><td>Private routing unaffected</td></tr>
  <tr><td><strong>lelastic (BGP)</strong></td><td>✅ Active on backup</td><td>Route advertisement handled by active node</td></tr>
</table>

<div class="ok">
Your services continue to operate normally with <strong>zero downtime</strong> while you rebuild the failed node.
</div>

<hr>

<h2>2️⃣ Preparation Before Recovery</h2>

<ol>
  <li>Confirm the failed node (e.g., <code>nat1-a</code>) is powered off or deleted in Linode Cloud Manager.</li>
  <li>Ensure the backup node (<code>nat1-b</code>) is currently <strong>MASTER</strong>:
    <pre>systemctl status keepalived | grep STATE
ip addr show eth0 | grep fip</pre>
  </li>
  <li>Verify private node traffic still reaches the Internet:
    <pre>curl -s https://api.ipify.org</pre>
  </li>
</ol>

<hr>

<h2>3️⃣ Recreate the Node Using Terraform</h2>

<p>Your Terraform configuration already defines static VLAN IPs and roles:</p>

<pre><code>members = [
  { label = "nat1-a", vlan_ip = "192.168.1.3/24", state = "MASTER", priority = 150 },
  { label = "nat1-b", vlan_ip = "192.168.1.4/24", state = "BACKUP", priority = 100 }
]
</code></pre>

<p>No edits are required — simply reapply the infrastructure:</p>

<pre><code>cd terraform
export TF_VAR_linode_token=&lt;YOUR_LINODE_TOKEN&gt;
terraform apply -auto-approve
</code></pre>

<p>This will automatically:</p>
<ul>
  <li>Detect that <code>nat1-a</code> no longer exists</li>
  <li>Recreate it with the same VLAN IP and public FIP</li>
  <li>Reattach it to the correct VLAN and IP-sharing configuration</li>
</ul>

<hr>

<h2>4️⃣ Reconfigure the Node with Ansible</h2>

<p>After Terraform completes, bring the node into full sync with Ansible:</p>

<pre><code>cd ../ansible
ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i inventory.ini site.yml
</code></pre>

<div class="note">
Running the playbook across all hosts is safe and recommended — Ansible is idempotent, so no configuration will be overwritten unnecessarily.
</div>

<hr>

<h2>5️⃣ Failover Simulation (Optional Test)</h2>

<ol>
  <li>On the recovered node (<code>nat1-a</code>), stop Keepalived temporarily:
    <pre>systemctl stop keepalived</pre>
  </li>
  <li>Watch backup node logs:
    <pre>journalctl -u keepalived -f</pre>
  </li>
  <li>Traffic should continue uninterrupted via the backup.</li>
  <li>Restart Keepalived on the recovered node:
    <pre>systemctl start keepalived</pre>
  </li>
  <li>Observe re-election to ensure roles sync correctly.</li>
</ol>

<hr>

<h2>6️⃣ Post-Recovery Checks</h2>

<table>
  <tr><th>Check</th><th>Command</th><th>Expected Output</th></tr>
  <tr><td>NAT Rules Active</td><td><code>sudo nft list ruleset | grep snat</code></td><td>SNAT with correct public IP</td></tr>
  <tr><td>FIP Present</td><td><code>ip addr show eth0 | grep fip</code></td><td>One FIP assigned</td></tr>
  <tr><td>VRRP Role</td><td><code>systemctl status keepalived | grep STATE</code></td><td>MASTER or BACKUP</td></tr>
  <tr><td>Conntrack Sync</td><td><code>conntrackd -s</code></td><td>Peer reachable and syncing</td></tr>
  <tr><td>BGP Route (lelastic)</td><td><code>systemctl status lelastic</code></td><td>Running and stable</td></tr>
</table>

<hr>

<h2>7️⃣ Best Practices & Notes</h2>

<ul>
  <li>Keep <code>terraform.tfstate</code> and <code>inventory.ini</code> version-controlled.</li>
  <li>Do not run Terraform from multiple systems at once.</li>
  <li>Rerunning <code>ansible-playbook</code> for the full inventory is safe.</li>
  <li>Test VRRP failover periodically to confirm state and IP sync.</li>
  <li>Always export your Linode API token securely using:
    <pre>export TF_VAR_linode_token=&lt;YOUR_LINODE_TOKEN&gt;</pre>
  </li>
</ul>

<hr>

<h2>✅ Summary</h2>

<table>
  <tr><th>Step</th><th>Action</th><th>Outcome</th></tr>
  <tr><td>1️⃣</td><td>Identify failed node</td><td>Backup continues serving traffic</td></tr>
  <tr><td>2️⃣</td><td>Recreate using Terraform</td><td>Node rebuilt with same IPs</td></tr>
  <tr><td>3️⃣</td><td>Reconfigure via Ansible</td><td>Services started and synced</td></tr>
  <tr><td>4️⃣</td><td>Test failover</td><td>Failover verified successfully</td></tr>
</table>

<div class="ok">
<strong>Result:</strong> Your Linode HA NAT Gateway remains resilient, recoverable, and ready for production workloads.
</div>

</body>
</html>
