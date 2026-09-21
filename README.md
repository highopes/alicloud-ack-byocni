# ACK BYOCNI Cilium/Tetragon Demo

本仓库从本地 MacBook 一键创建和销毁 Alibaba Cloud ACK Managed Kubernetes Pro 演示环境。正常生命周期只有两个入口：

```bash
./kup
./kiall
```

`kup` 使用 Terraform 创建 ACK、VPC、vSwitch、NAT 与 3 个 Worker，再通过项目私有 kubeconfig 安装 Cilium Enterprise、Hubble Enterprise、Standalone Timescape Lite、Hubble UI Enterprise、Tetragon Enterprise、Tetragon Policies、Alibaba Registry 版本的 mini-boutique、非阻断式 L7 visibility policy，以及 [Galileo Multi-agent banking chatbot](https://github.com/highopes/galileo-demo)。`kiall` 只销毁当前 Terraform state 拥有的资源。

## Architecture

```text
MacBook
  |-- Terraform --------------------------> ACK Pro / VPC / workers
  |-- kubectl + Helm (private kubeconfig)     |
                                               +-- Cilium Enterprise
                                               |     +-- Native Routing
                                               |     +-- Kubernetes IPAM
                                               |     +-- Kube Proxy Replacement
                                               |     +-- Hubble Relay
                                               |
                                               +-- Hubble UI Enterprise
                                               |     +-- live: Hubble Relay
                                               |     +-- history: Timescape
                                               |
                                               +-- Hubble Enterprise --push--+
                                               |                           |
                                               +-- Standalone Timescape <--+
                                               |     +-- ephemeral ClickHouse
                                               |
                                               +-- Tetragon Enterprise
                                               |     +-- Tetragon Policies
                                               |     +-- network/alert logs
                                               |
                                               +-- demo: mini-boutique + L7 CNP
                                               +-- test: testcurl DaemonSet
                                               +-- galileo-demo
                                                     +-- Chainlit / LangGraph
                                                     +-- projected Prompt ConfigMap
                                                     +-- Bailian Qwen application model
                                                     +-- Pinecone integrated search
                                                     +-- Splunk Agent Observability
```

这是 ACK BYOCNI + VPC Route/Native Routing 方案，不是 Terway chaining。Cilium chart 内置的 Integrated Timescape 已禁用；历史流量使用独立的 Timescape Lite，Hubble Enterprise 按 AWS 已验证方案把 flow 推送到其 ingestion endpoint。UI 使用 ClusterIP 与本地 port-forward，不创建公网 LoadBalancer。

## One-time Alibaba prerequisites

使用 Alibaba Cloud 中国站账号，并确认后付费账户可用且余额足以创建 ACK Pro、3 台按量付费 ECS Worker、NAT Gateway 与公网 API Server SLB。正常流程不使用 Cloud Shell。

1. 首次进入 ACK 控制台时激活 ACK 服务，并接受 ACK 所需的 Service Role / Quick Authorization。
2. 如果 `AliyunOOSLifecycleHook4CSRole` 等服务角色需要短信、人脸或其他人工安全验证，在控制台完成一次性授权。
3. 创建专用 RAM User。它需要管理本 Demo 涉及的 ACK/CS、ECS、VPC、vSwitch、NAT、EIP/SLB，以及读取可用区和实例规格的权限。可按组织要求授予相应 Alibaba Cloud 系统策略，或使用覆盖这些操作的最小权限自定义策略。不要使用主账号 AccessKey；Cloud Shell 专用权限不再需要。
4. 为 RAM User 创建 AccessKey：
   - 登录 Alibaba Cloud Console。
   - 打开 **Resource Access Management (RAM)**。
   - 进入 **Identities -> Users**。
   - 选择 Demo 自动化使用的 RAM User。
   - 打开 **Credential / Authentication** 页面。
   - 找到 **AccessKey**，点击 **Create AccessKey**。
   - 完成短信、人脸或其他安全验证。
   - 立即保存 AccessKey ID 与 AccessKey Secret。

AccessKey Secret 通常只完整显示一次。如果已经无法取得旧 Secret，请新建一对 AccessKey 并废弃旧 Key，不要尝试恢复。

## Mac prerequisites

本地 Mac 需要：

- Terraform 1.7 或更新的 1.x
- kubectl
- Helm
- Python 3
- curl、awk、sed、base64

Homebrew 示例：

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform kubectl helm python3
```

## Configure

```bash
cp kup.conf.example kup.conf
vim kup.conf
```

先填写 ACK 的三个基础凭据：

```bash
ALICLOUD_ACCESS_KEY="ReplaceMe"
ALICLOUD_SECRET_KEY="ReplaceMe"
ACK_NODE_PASSWORD="ReplaceMe"
```

`ACK_NODE_PASSWORD` 不是从 Alibaba Cloud 查询得到的；它是创建 Worker Node Pool 时由你设置的 ECS 登录密码。为这个 disposable Demo 创建一个满足 Alibaba Cloud 规则的独立强密码。正常演示不依赖 SSH。

Galileo 应用还需要填写以下 `GALILEO_*` 设置；`kup.conf.example` 只提供 `ReplaceMe`，真实值只能留在私有 `kup.conf`：

```text
GALILEO_IMAGE_REF                 ACR 中 linux/amd64 immutable @sha256 digest
GALILEO_REGISTRY_SERVER          ACR registry host
GALILEO_REGISTRY_USERNAME        ACR pull username
GALILEO_REGISTRY_PASSWORD        ACR pull password
GALILEO_SPLUNK_AO_API_KEY        Splunk Agent Observability API key
GALILEO_APP_MODEL_BASE_URL       OpenAI-compatible HTTPS endpoint
GALILEO_APP_MODEL_API_KEY        当前应用模型的 API key
GALILEO_PINECONE_API_KEY         Pinecone API key
```

`GALILEO_SUPERVISOR_PROMPT_PROFILE` 控制 `kup` 安装后进入 baseline 演示还是直接进入 improved，取值为 `baseline`（默认）或 `improved`。当它是 `baseline` 时，新变量 `GALILEO_BASELINE_PROMPT_VARIANT` 决定采用哪套 baseline：默认 `qwen` 等价于执行上游命令 `custom app/prompts/supervisor-baseline-qwen.txt`；`official` 等价于执行上游命令 `baseline`。若 profile 是 `improved`，baseline variant 不生效，`kup` 执行上游的 `improved`。该变量只是 `kup` 完成安装时选择哪条上游命令，不定义任何新的运行时 profile。`GALILEO_PROMPT_SYNC_TIMEOUT_SEC` 是 `kup` 等待 projected ConfigMap 被应用 resolver 读到的最终复核上限，默认 300 秒。

本次验证的私有 `kup.conf` 已从同级 Galileo working copy 的 `.secrets` 与 `.runtime` resolved files 初始化：应用使用百炼 `qwen3.7-flash`、隔离 Pinecone index `credit-card-information-qwen-demo`，镜像仍固定为上游 commit `26ea7c0c3276cde94b6f5c1bff2b0d741d655858` 对应的 ACR digest。上游 commit `4ce9a4d24adc3bf91783cd68383a79b63e46cad4` 没有要求更换当前镜像；本仓库把 Qwen baseline 保存在与上游相同的 `app/prompts/supervisor-baseline-qwen.txt`，并使用同一份 `scripts/switch_prompt.sh` 动态加载。`kup` 不需要 Docker，也不会重新 build/push 镜像。真正更新应用镜像时，应先在 Galileo repo 重新完成 build、push 和 smoke，再一起更新 `GALILEO_SOURCE_COMMIT` 与 `GALILEO_IMAGE_REF`，禁止使用 `latest`。

运行期 Pod 只注入 Splunk AO、最终 application model 与 Pinecone 三个 key；VLLM Judge key、Docker Hub PAT、RAM AccessKey 和 ACR push credential 不会进入应用 Pod。若要展示四个 Qwen Evaluator 或 Experiment，需预先在 Splunk AO UI 中确认 Project、Agent Stream、Evaluator 与 Dataset；`kup` 不修改这些控制面对象。

还必须在私有 `kup.conf` 中手工增加：

```bash
ISO_REPO_URL="<authorized-enterprise-helm-repository>"
```

The Isovalent Enterprise Helm repository URL is intentionally omitted from kup.conf.example. Obtain it from an existing authorized Isovalent Enterprise configuration or the appropriate Cisco/Isovalent entitlement source, and add ISO_REPO_URL to the private kup.conf.

优先从已经工作的本地 AWS Demo 私有配置复制该值：

```text
/Users/hangwe/Library/CloudStorage/OneDrive-Cisco/dev/isovalent/aws/kup.conf
```

`kup.conf`、`kubeconfig`、Terraform state 与渲染文件均被 Git 忽略。两个入口会把私有配置设为 0600，生成的 kubeconfig 也固定为 0600。Galileo 的 Kubernetes Secret 通过 0600 临时文件创建并立即清除，不进入 `runtime/` 的持久文件。不要把私有值提交、复制到日志或合并进 `~/.kube/config`。

默认值已包含区域、CIDR、3 个 Worker、实例规格、磁盘、稳定 context、chart 版本、namespace 与本地端口。Standalone ClickHouse 请求 4 GiB 内存，因此默认 Worker 使用 4 vCPU/8 GiB 的 `ecs.e-c1m2.xlarge`；Galileo 只运行应用 Pod，不在 ACK 节点运行模型。节点镜像为支持 ACK 当前 cgroup v2 要求的 AliyunLinux3 Container Optimized。

## Create

```bash
./kup
```

创建通常需要较长时间。ACK Worker 在 Cilium 安装前显示 `NotReady` 是 BYOCNI 的预期行为；脚本先确认 Node 对象与 PodCIDR 已出现，再安装 Cilium，然后等待所有节点 `Ready`。

`kup` 是幂等的。第一次因 Ctrl-C、网络中断或临时镜像错误停止后，修复原因并再次运行 `./kup` 即可继续收敛；重复执行不会创建第二套 VPC 或 ACK 集群。Terraform 与 Helm 都有有限重试，Helm 命令返回后还会强制确认 release 为 `deployed`；中断留下的最新 `pending-*` revision 会在重试前精确移除，不会删除 workload 或任何 deployed revision。

脚本结束前会自动验证三节点 Ready/PodCIDR、Cilium health、Hubble flow export、Hubble Enterprise -> Timescape ingestion、所有应用 Pod Ready、DNS、pod-to-pod、pod-to-service、外部 HTTPS，以及每节点 Tetragon BPF LSM probe、network event、alert event、TracingPolicy 与 AlertRule。Galileo 还会验证 immutable image、Prompt ConfigMap 键、projected volume/env 路径、运行中应用解析到的 profile、ClusterIP HTTP、模型 DNS/TLS/认证与精确 model ID、Pinecone integrated text search，以及 Splunk AO HTTPS。任一硬检查失败都会返回非零状态。

自动化只使用：

```text
./kubeconfig
context: ack-byocni-demo
```

所有 Kubernetes/Helm 操作显式指定该文件和 context，不读取或改变全局 current-context，因此不会影响同一台 Mac 上的 AWS EKS context。

## Apply Galileo configuration changes

集群已经由 `./kup` 完整部署后，如果只修改了私有 `kup.conf` 中的 `GALILEO_*` 或 Multi-Agent Banking Chatbot 参数，不要为了让应用读取新值而重新执行完整部署。运行：

```bash
./kup --galileo-only
```

这个模式只收敛 `galileo-demo` namespace 中的两个 Secret、ConfigMap、Service 和 `splunk-ao-banking-qwen` Deployment；它不会运行 Terraform，也不会升级或重启 ACK Node、Cilium、Hubble、Timescape、Tetragon、mini-boutique 或 testcurl。

不同参数的生效方式如下：

| `kup.conf` 修改类型 | 生效方式 | 影响范围 |
|---|---|---|
| `GALILEO_SPLUNK_AO_API_KEY`、应用模型/Pinecone key，以及由环境变量读取的 Project、Agent Stream、模型、index、Evaluator/Dataset 等运行时参数 | `./kup --galileo-only` 更新 Secret/ConfigMap；Pod 模板校验和变化后自动滚动 | 只替换 Chatbot 的一个 Pod；RollingUpdate 会先创建新 Pod，再移除旧 Pod |
| `GALILEO_IMAGE_REF`、`GALILEO_SOURCE_COMMIT` | `./kup --galileo-only` 应用新的不可变镜像与来源标记 | 只滚动 Chatbot Deployment |
| ACR pull 用户名或密码 | `./kup --galileo-only` 更新 imagePullSecret；若镜像未变，现有 Pod 无需重启 | 只影响以后拉取 Chatbot 镜像 |
| `GALILEO_SUPERVISOR_PROMPT_PROFILE`、`GALILEO_BASELINE_PROMPT_VARIANT` | `./kup --galileo-only` 使用现有 projected ConfigMap 热加载 | Pod 与镜像保持不变；新建 Chainlit 聊天后使用新提示词 |
| 只临时切换 baseline/improved/custom prompt | 直接运行下文的 `./scripts/switch_prompt.sh ...`，无需修改 `kup.conf` | 不重启 Pod |
| `GALILEO_LOCAL_PORT`、`GALILEO_PROMPT_SYNC_TIMEOUT_SEC` | 下次本地 port-forward 或收敛命令直接读取 | 不修改集群工作负载 |

Secret 和通过 `envFrom` 注入的 ConfigMap 值只会在 Pod 启动时读取；只编辑 `kup.conf` 或只更新 Kubernetes Secret，不会改变已经运行的进程。因此不要省略上述 Galileo-only 收敛。命令结束前会等待 rollout 完成，并在新 Pod 内验证 prompt、HTTP、精确模型 ID、Pinecone 查询和 Splunk AO HTTPS；失败时返回非零状态。若修改 `GALILEO_NAMESPACE`，该命令会在新 namespace 部署一套应用，但不会猜测并删除旧 namespace，需把它视为迁移而不是普通参数刷新。

## Validate

先定义一个便于复制的只读 wrapper：

```bash
kctl() {
  kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo "$@"
}
```

ACK、PodCIDR 与节点状态：

```bash
kctl get nodes -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,PODCIDR:.spec.podCIDR,VERSION:.status.nodeInfo.kubeletVersion'
```

Cilium、Kubernetes IPAM、Native Routing、KPR 与 Hubble：

```bash
kctl -n kube-system get deployment/cilium-operator daemonset/cilium deployment/hubble-relay
kctl -n kube-system exec daemonset/cilium -c cilium-agent -- cilium-dbg status
kctl -n kube-system exec daemonset/cilium -c cilium-agent -- cilium-dbg config --all | grep -E 'routing-mode|ipam|kube-proxy-replacement'
```

Hubble Enterprise、Standalone Timescape/ClickHouse 与 Hubble UI：

```bash
helm --kubeconfig ./kubeconfig --kube-context ack-byocni-demo -n kube-system list
kctl -n kube-system get pods,svc,endpoints | grep -E 'hubble|timescape|clickhouse'
kctl -n kube-system logs -l app.kubernetes.io/instance=hubble-enterprise --tail=100 | grep -Ei 'error|failed' || true
```

Tetragon Agent、BPF LSM、policy 与日志目录：

```bash
kctl -n kube-system get daemonset/tetragon pods -l app.kubernetes.io/name=tetragon -o wide
kctl get tracingpolicies
kctl get alertrules
for p in $(kctl -n kube-system get pod -l app.kubernetes.io/component=agent,app.kubernetes.io/name=tetragon -o name); do
  kctl -n kube-system logs "$p" -c tetragon --tail=20000 | grep -F 'HaveProgramType(ebpf.LSM) = true'
  kctl -n kube-system exec "$p" -c tetragon -- sh -c \
    'test -s /var/run/cilium/hubble/tetragon.log && find /var/run/cilium/hubble/alert -type f -size +0 -print -quit | grep -q .'
done
```

当前 Tetragon chart 不会把 Host securityfs 挂入 Agent 容器，因此不能用容器内 `/sys/kernel/security/lsm` 是否存在来判断 Host BPF LSM。上面的 Agent feature probe 与非空 network/alert export 是 `kup` 使用的运行期硬检查。

mini-boutique、L7 policy 与 testcurl：

```bash
kctl -n demo get deployments,pods,services
kctl -n demo get ciliumnetworkpolicy demo-l7-visibility-no-block -o yaml
kctl -n test get daemonset/testcurl pods -o wide
TEST_POD=$(kctl -n test get pod -l app=testcurl -o jsonpath='{.items[0].metadata.name}')
kctl -n test exec "$TEST_POD" -- nslookup kubernetes.default.svc.cluster.local
kctl -n test exec "$TEST_POD" -- curl -fsS http://frontend.demo.svc.cluster.local/ >/dev/null
kctl -n test exec "$TEST_POD" -- curl -fsSI https://www.cisco.com/
```

Galileo multi-agent banking chatbot：

```bash
kctl -n galileo-demo get deployment,pods,service
kctl -n galileo-demo get deployment splunk-ao-banking-qwen \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
GALILEO_POD=$(kctl -n galileo-demo get pod \
  -l app.kubernetes.io/name=splunk-ao-banking-qwen -o json | \
  python3 -c 'import json,sys; p=json.load(sys.stdin)["items"]; print(next(x["metadata"]["name"] for x in p if not x["metadata"].get("deletionTimestamp") and any(c["type"] == "Ready" and c["status"] == "True" for c in x.get("status", {}).get("conditions", []))))')
kctl -n galileo-demo exec "$GALILEO_POD" -- python pod_network_smoke.py
kctl -n test exec "$TEST_POD" -- \
  curl -fsS http://splunk-ao-banking-qwen.galileo-demo.svc.cluster.local/ >/dev/null
KUBECONFIG_FILE="$PWD/kubeconfig" KUBE_CONTEXT="ack-byocni-demo" \
  KUBE_NAMESPACE="galileo-demo" ./scripts/switch_prompt.sh status
```

## Hubble UI access

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n kube-system \
  port-forward svc/hubble-ui 18080:80
```

打开 <http://127.0.0.1:18080>。Live 视图来自 Hubble Relay，Historical 视图来自 Standalone Timescape。无需也不应创建公网 UI LoadBalancer。

## Galileo banking chatbot demo

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n galileo-demo \
  port-forward svc/splunk-ao-banking-qwen 8000:80
```

打开 <http://127.0.0.1:8000>。这是 Galileo repo 的 Chainlit/LangGraph Multi-agent banking chatbot；Service 保持 ClusterIP，不创建 Ingress 或公网 LoadBalancer。

ACK 项目的 `scripts/switch_prompt.sh` 默认从 `kup.conf` 读取项目 kubeconfig、ACK context 与 Galileo namespace，因此可在仓库根目录直接运行。需要指向其他集群时，也可以显式覆盖连接参数：

```bash
export KUBECONFIG_FILE="$PWD/kubeconfig"
export KUBE_CONTEXT="ack-byocni-demo"
export KUBE_NAMESPACE="galileo-demo"
```

这三个变量是上游脚本原生支持的通用 Kubernetes 接口，不会引入第二套状态或命令。运行 `./scripts/switch_prompt.sh status` 可核对 ConfigMap、挂载文件、应用 resolver、Prompt SHA-256 与 Deployment 镜像。

两个 repository 没有各自保存一份“当前提示词状态”。唯一运行时事实来源始终是同一个 `galileo-demo/splunk-ao-banking-qwen-config` ConfigMap；在任一 repository 中执行切换，另一个 repository 的 `status` 会立即观察到同一结果。再次执行 `./kup --galileo-only`（或完整的 `./kup`）时，会按 `kup.conf` 的目标状态调用同一上游脚本重新收敛。

### 三套演示提示词与切换

当前不可变镜像保留官方 baseline；Qwen baseline 不覆盖它，而是复用动态 `custom` profile。三套提示词及命令如下：

| 演示提示词 | 切换命令 | 应用 profile / Session 标签 | 用途 |
|---|---|---|---|
| 官方 baseline | `./scripts/switch_prompt.sh baseline` | `baseline` / `[baseline]` | 当前镜像内置的官方故意不完整版本，更适合 GPT 类模型 |
| Qwen baseline | `./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt` | `custom` / `[custom]` | 针对 Qwen 构造的故障版；这是 `kup.conf.example` 和当前私有配置的默认值 |
| improved | `./scripts/switch_prompt.sh improved` | `improved` / `[improved]` | 明确支持 credit-score agent，并正确交付工具结果 |

这与上游完全采用同一套 `baseline | improved | custom FILE` 状态模型，没有额外 alias。脚本会等待 ConfigMap 投影和应用 resolver 收敛；`custom` 还会校验实际 Prompt SHA-256。升级后的 Deployment 只做热更新，不重启 Pod；只有检测到未挂载 projected ConfigMap 的旧 Deployment 时，才按上游兼容逻辑滚动一次。切换完成后必须在 Chainlit 中**新建聊天**；已开始的聊天继续使用创建 Session 时的 prompt。

### 第一阶段：Qwen baseline 故障演示

`kup` 默认以 `GALILEO_SUPERVISOR_PROMPT_PROFILE="baseline"` 和 `GALILEO_BASELINE_PROMPT_VARIANT="qwen"` 结束安装，也可以在演示前显式恢复同一状态：

```bash
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
./scripts/switch_prompt.sh status
```

建议按以下顺序演示：

1. 新会话输入 `What is my credit score?`，确认 supervisor 只转交一次 credit-score agent、底层工具返回 `550`，但回到 supervisor 后最终回答 `I cannot answer that question`。
2. 输入 `What are the cashback rewards offered by the Orbit Credit Card?`，预期 credit-card agent 使用 Pinecone，grounded answer 应说明 Orbit Basic 没有 cashback/rewards。
3. 输入 `Recommend me a good book.`，预期 supervisor 不调用银行业务 agent，并回答不知道或无法回答。
4. 在 Splunk AO 对应 Project/Agent Stream 中展开 supervisor、sub-agent、tool 与 model spans，对照 Action Advancement、Action Completion、Tool Errors、Tool Selection Quality 四个 Evaluator；Qwen baseline 的 Session 名称包含 `[custom]`。

两套 baseline 都保留官方样例“已存在 credit-score agent，但 supervisor 支持能力只描述 credit-card agent”的故意缺陷。官方文本在 GPT 类模型上适合作为第一阶段，但 `qwen3.7-flash` 会从 tool schema 自动推断缺失能力并正确返回 `550`，从而掩盖故障。Qwen 版因此明确要求只做一次最相关 handoff；score agent/tool 正常返回后，因为 supervisor 仍没有被告知如何交付未列明能力的结果，它会进入原有兜底并回答 `I cannot answer that question`。这只调整 supervisor prompt，不修改 Agent、Graph、工具、固定答案或镜像。

### 第二阶段：切换 improved prompt

不修改源码、镜像或 Pod，直接把 ConfigMap 切到上游内置的 `improved` profile：

```bash
./scripts/switch_prompt.sh improved
```

这个 profile 明确给 supervisor 增加 credit-score agent 能力描述并正确交付返回结果。新建聊天后重复 `What is my credit score?`，预期返回工具支持的 `550`。新 Splunk AO Session 名称包含 `[improved]`，可与 Qwen baseline 的 `[custom]` Trace/Evaluator 结果对比。

### 其他：任意自定义 prompt

将 UTF-8 文本文件写入非 Secret ConfigMap；脚本拒绝空文件和大于 100 KiB 的内容，并验证应用实际解析内容的 SHA-256：

```bash
# 使用仓库附带的生产化 routing contract 示例
./scripts/switch_prompt.sh custom app/prompts/supervisor-production-example.txt

# 或使用自己的文件
./scripts/switch_prompt.sh custom /absolute/path/to/supervisor-prompt.txt
```

切换完成后新建 Chainlit 聊天，Splunk AO Session 名称会包含 `[custom]`。自定义 prompt 保存在 ConfigMap 中，对有该 namespace 读取权限的人可见，因此不要在提示词中放密码、API key、客户隐私或其他 Secret。

Kubernetes ConfigMap 投影是最终一致的；上游脚本按同样的 90 次、每次 2 秒方式等待，不需要手工重启 Pod。如果超时，命令会失败，不能把 ConfigMap 已修改误报成应用已生效。`GALILEO_PROMPT_SYNC_TIMEOUT_SEC` 只控制 `kup` 随后的最终一致性复核。查看原始配置可执行：

```bash
kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo \
  -n galileo-demo get configmap splunk-ao-banking-qwen-config \
  -o jsonpath='{.data.SUPERVISOR_PROMPT_PROFILE}{"\n"}'
```

演示结束后恢复默认 Qwen baseline：

```bash
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
```

如需验证官方 baseline，执行 `./scripts/switch_prompt.sh baseline`；这会清空 custom 内容并回到镜像内置文本。再次运行 `./kup --galileo-only`（或完整的 `./kup`）会通过同一上游脚本恢复私有配置指定的 profile 和 baseline variant，默认重新热加载 Qwen baseline，防止下一场演示沿用上次状态。`kup` 和 prompt 切换脚本都不会创建或修改 Splunk AO Evaluator/Dataset；Experiment 统一使用下一节的仓库入口，不直接运行镜像内的 `experiment.py`。

## Splunk AO Model Economics Experiment

`./scripts/galileo-experiment` 在当前唯一 Ready 的 Banking Pod 内执行镜像已有的真实 Multi-Agent workflow。`Banking CN Model Economics` 同名 Dataset 一旦存在，Splunk AO UI 中当前保存的全部行、input 和 Ground Truth 就是本次 Experiment 的权威来源；可以先在 UI 修改 Ground Truth，再运行脚本展示新的对照结果。脚本不会把它与本地默认值比较，也不会覆盖、删除或重建它。只有同名 Dataset 不存在时，脚本才用内置的 6 行默认内容创建并重新读取确认。Evaluator 对象继续由 Splunk AO GUI 管理，脚本不创建、修改或删除它们。

推荐先使用 improved prompt 运行第一个 application model：

```bash
# model 1
vim kup.conf
# GALILEO_APP_MODEL_NAME="qwen3.7-flash"
# GALILEO_SUPERVISOR_PROMPT_PROFILE="improved"

./kup --galileo-only
./scripts/galileo-experiment
```

然后只切换 application model，保持其他变量不变：

```bash
# model 2
vim kup.conf
# GALILEO_APP_MODEL_NAME="qwen3.8-max"

./kup --galileo-only
./scripts/galileo-experiment
```

脚本从运行中 Pod 读取真实 `APP_MODEL_NAME` 并写入 Experiment 名称；如果 Pod 与 `kup.conf` 的 model、Project、Agent Stream 或 Console 配置不同，会停止并要求先完成 `./kup --galileo-only`。Prompt 是例外：`switch_prompt.sh` 支持随时热切换，因此脚本只信任并展示当前 Pod resolver 返回的 profile，不要求它与 `kup.conf` 一致，也不会自动切换 prompt。

Evaluator 也是 Experiment 级配置，不要求提前在 Agent Stream 中激活。Demo 1 的 Stream 继续保留原来的 4 个 Evaluator；Demo 2 脚本只从 `GALILEO_SPLUNK_AO_EXPERIMENT_EVALUATORS` 选择 `Ground Truth Adherence - Qwen`，通过 SDK 的 Scorer 列表动态解析为稳定 ID 并绑定到本次 Experiment，不改变 Demo 1 的 Stream 配置，也不重复运行另外 4 个 Evaluator。若 Ground Truth Evaluator 尚未配置或不存在，脚本给出 warning，但仍生成业务输出和 Trace。脚本不会在本地安装 Python 依赖。

随后在 Splunk AO GUI 中进入 `Experiments`，比较两次运行的 Ground Truth / Generated Output、Evaluators、Tokens、Cost、Latency，以及各自的 Trace/Span：

```text
Same Agent
Same Prompt
Same Dataset
Same RAG
Same Tools
Same Evaluators
Only the application model changes
```

Experiment 的 Trace 上传完成后，脚本会按照启动时读取的 UI Dataset 行数，确认每条根 Trace 的原生子 Span 已稳定落库，且每条至少有一个带真实 provider token usage 的成功 LLM Span；明确记录为 `Error: Request timed out.` 的失败尝试会保留，但不会被误判为成功调用缺少 Token。随后脚本才完成根记录并从后端读回验证：Dataset input、UI 当前 Ground Truth、generated output、子 Span、LLM model 和成功 LLM Span 的 input/output/total token usage 都必须完整。每条根 Trace 的 Cost、Input/Output/Total Tokens、Latency 也必须已有数值，不能只凭子 Span 有 token 就报告成功。各阶段最多等待 180 秒，缺少任一项明确返回非零。此验收不等待 Judge 分数；Ground Truth Eval 的 pending/failed 项可稍后在 GUI 中 Compute/Recompute。Ctrl-C 不会删除 Dataset 或 Experiment。

Instrumentation 使用 `SplunkAOCallback`，全部子 Span 通过 SDK 原生 OTLP 上传，Cost/Tokens 由平台计算。当前 legacy hosted Galileo（`app.galileo.ai`）的 OTLP 接收路径未保留 Dataset 字段，因此入口在每行 Agent 执行前，先通过官方 SDK 创建只含该次 UI Dataset input/Ground Truth 的根记录，使用与该行 OTLP 相同的 Trace ID，子 Span 列表为空。随后 Callback 原样上传子 Span；脚本确认原生 Span 和 token usage 稳定后，再通过官方 SDK 完成同一个根记录的 output、status 和实测 duration。不会创建第二条业务 Trace、重复上传子 Span或手工填写 Cost/Tokens。此适配只作用于 Experiment 进程，不修改镜像、Agent 或 Demo 1 Stream。为了避免 Judge 在 generated output 尚未写入时提前计算，现有 Ground Truth scorer 会在全部根记录完成后绑定到 Experiment，并与后续根级 Cost/Token 验收解耦；即使平台不能为某个新模型生成标准指标，也不会跳过 Ground Truth Eval。平台可以异步计算 Judge，脚本不额外提交 Recompute，也不等待 Judge 结果。应用模型 timeout 最多尝试三次，最终失败则明确返回非零。

## Export Model Economics data for Splunk Enterprise

`./scripts/export-banking-cn-economics` 通过当前唯一 Ready 的 Banking Pod 和其中已经固定的 `splunk-ao==0.4.0`，只读导出当前 Project 内名称以 `Banking CN Economics` 开头的全部 Experiment。它查询 Experiment、根 Trace 与完整 Span 树，不调用 Agent、不创建或修改 Splunk AO 对象，也不从公开价格表推算费用。默认结果写入 `data/banking_cn_economics.csv`：

```bash
./scripts/export-banking-cn-economics

# 可选：导出到其他位置，或改变 Experiment 前缀
./scripts/export-banking-cn-economics --output /absolute/path/banking_cn_economics.csv
./scripts/export-banking-cn-economics --prefix 'Banking CN Economics'
```

写入是原子的：远端 API、Kubernetes 连接或本地校验失败时不会替换现有 CSV。Splunk AO 的 timeout、502、503、504、上游 reset 与 rate limit 会有限重试三次，持续失败仍返回非零。CSV 使用 UTF-8 和 LF，一条 Trace 对应一个物理行；Ground Truth、Generated Output 与 Judge rationale 中的换行编码为字面量 `\n`，便于 Splunk Enterprise 作为 CSV lookup 稳定读取。CSV 不包含 API key、kubeconfig、RAM credential 或 Pod Secret。

主要字段按以下口径生成：

| 维度 | CSV 字段 | 口径 |
| --- | --- | --- |
| 质量 | `ground_truth_adherence_score`、`ground_truth_adherence_pass`、`ground_truth_adherence_scored` | 动态查找 alias 以 `Ground Truth Adherence` 开头的 Trace metric。严格以 score `1` 为合格，未完成 Judge 的行保持空值而不是误记为不合格。 |
| 详细性 | `supervisor_output_tokens` | 顶层 `invoke_agent brahe-bank-supervisor-agent` Span 的汇总 output tokens；包含该 Supervisor 调用树中的下游 Agent，是 Dashboard 的主比较指标。 |
| Supervisor 自身开销 | `supervisor_direct_output_tokens`、`supervisor_direct_turn_count` | 只合计 `invoke_agent brahe-bank-supervisor-agent:Agent` 的直接推理轮次，排除 credit-card/credit-score 子 Agent。 |
| 性能 | `trace_duration_seconds` | 根 Trace 的后端 `duration_ns` 除以 `1e9`，不使用页面格式化字符串。 |
| 价格 | `trace_cost_usd` | 根 Trace 的平台 Cost；Judge 的独立费用保存在 `judge_cost_usd`，两者不混加。 |
| 运行复杂度 | `span_count`、`llm_call_count`、`tool_call_count`、`retriever_call_count`、`error_span_count` | 从该 Trace 的完整 Span 树直接计数。 |
| 可比性 | `dataset_id`、`dataset_version`、`scenario_key`、`comparison_ready` | `scenario_key` 由 Dataset input 稳定生成；核心指标、Judge 与 Supervisor 数据齐全且 Trace 成功时 `comparison_ready=1`。 |

Dashboard 应按 `experiment_id` 聚合，不能把同一 model 的多次运行静默合并。各 Experiment 的总耗时、总费用、Supervisor 输出数与合格率分别使用 `sum(trace_duration_seconds)`、`sum(trace_cost_usd)`、`sum(supervisor_output_tokens)` 和 `sum(ground_truth_adherence_pass) / sum(ground_truth_adherence_scored)`。如果 `dataset_version` 不一致，必须显示可比性警告，并以 `scenario_key` 对齐共同场景。

当前提交的 CSV 快照已在线读回并通过本地结构校验，共 2 个 Experiment、12 条 Trace，全部 `comparison_ready=1`：

| Application model | Dataset version | Ground Truth 合格 | 6 Trace 总耗时（秒） | 6 Trace 总费用（USD） | Supervisor output tokens |
| --- | ---: | ---: | ---: | ---: | ---: |
| `qwen3.7-flash` | 1 | 6/6（100%） | 478.763938 | 0.002528790050 | 16,878 |
| `qwen3.8-max` | 6 | 6/6（100%） | 157.938983 | 0.105030042003 | 4,917 |

两个现有运行的 Dataset version 分别为 1 和 6，因此费用、性能和运行结构可以直接展示，质量结论则必须同时展示版本不一致提示，不能写成严格的单变量模型因果对比。重新运行导出器会从平台刷新同一路径的数据快照。

## Destroy

```bash
./kiall
```

这是 disposable demo 的故意破坏性入口。它直接执行 `terraform destroy -auto-approve`，不先做 Helm uninstall、namespace 删除或 Kubernetes 优雅卸载。只有 destroy 成功且 `terraform state list` 为空时，脚本才删除项目私有 kubeconfig；Terraform state 文件本身保留。如果 destroy 失败，state 与 kubeconfig 都会保留，修复后再次运行 `./kiall`。Terraform destroy 最多有限重试三次；退出钩子确保中断或失败时保留的 kubeconfig 权限仍为 0600。

`kiall` 不扫描账号、区域或 VPC，也不会删除 state 外“看起来像 Demo”的资源。再次执行 `./kiall` 应安全显示没有资源需要销毁。

## Troubleshooting

### Galileo Experiment 出现 Ground Truth N/A 或根级 Cost/Tokens 为空

当前私有配置使用的是 legacy hosted Galileo Console：`https://app.galileo.ai`，SDK 推导出的 API backend 为 `https://api.galileo.ai`。Banking 镜像则固定使用已经更名并演进到 Splunk Agent Observability 的 `splunk-ao==0.4.0` 和 `SplunkAOCallback`。这两者不是完全不兼容：旧后端能够接收 Callback 的原生 OTLP Span、LLM model、Token usage、工具调用和输出；实际兼容差异集中在 Experiment 根记录。

在旧后端上确认过的根因和失败模式如下：

* SDK 原生 OTLP 子 Span 可以完整到达，但 legacy 接收路径不会可靠地把 SDK Experiment 上下文中的 Dataset input/Ground Truth 保留到可供 Ground Truth Eval 使用的根 Trace。只使用 Callback 时会看到 Token/Cost，却可能得到 Ground Truth N/A。
* 反过来，如果用记录 API 替代原生 OTLP、重新上传整个 Trace/Span 树，Dataset 字段能够保留，但会绕过或扰乱后端对原生 Span 的标准指标处理，导致根级 Cost、Input/Output/Total Tokens 为空。不能用这种方式替换 Callback。
* 即使 Dataset 根记录和 Callback 子 Span 使用同一个 Trace ID，若在最后一批原生 Span 和 provider token usage 可搜索之前就把根记录标记 complete，旧后端可能过早结算根级指标；之后再次 PATCH complete 不保证重新汇总。
* Ground Truth Judge 不能在 generated output 尚未写入时绑定并抢跑，否则会基于 `output=null` 得到错误结果；但也不能等到根级 Cost/Token 验收成功后才绑定，否则标准指标失败会连带跳过独立的 Ground Truth Eval。
* 新 application model 刚上线或模型别名尚未被后端定价/指标目录识别时，LLM 子 Span 可能已经有真实 Token，但 Cost 暂时为 `null`，根级聚合也可能延迟。Cost 和根级标准指标由平台计算；脚本不根据公开价目表手工伪造，因为区域、缓存命中和计费模式可能不同。

因此 `galileo-experiment` 对 `app.galileo.ai` 使用一个受限的兼容流程：先通过官方 SDK 创建只含 UI Dataset input/Ground Truth 的根记录，并使用与 Callback OTLP 完全相同的后端 Trace ID 和 session；业务 Agent 和全部子 Span 仍由 `SplunkAOCallback` 原生上传；脚本连续确认每条根 Trace 的 Span 集合和真实 Token usage 稳定后，才完成同一个根记录的 generated output、status 和实测 duration；随后立即绑定现有 Ground Truth Evaluator，使其不受 Cost/Token 验收结果影响；最后读回验证根级 Cost、Tokens 和 Latency。该流程不重复上传子 Span、不手工计算 Metrics，也不修改镜像、Agent graph 或 Demo 1 Agent Stream。

这确实是为了在不 rebuild 镜像的前提下兼容当前旧 Galileo 云端后端，但切回新的 Splunk AO Console 后，脚本不会因此失效。它根据 Pod 中规范化后的 Console hostname 自动选择路径：

| Console/backend | Trace 路径 |
| --- | --- |
| `app.galileo.ai` / `api.galileo.ai` | 启用上述 legacy Dataset-root 兼容层，同时保留 Callback 原生 OTLP 子 Span |
| 其他由 `splunk-ao==0.4.0` Standalone 配置推导的 Console/API（包括新的 Splunk AO hosted backend） | 跳过 legacy root workaround，使用 SDK 原生 OTLP Experiment 路径 |

新的 Splunk AO backend 路径已经按 SDK 合约实现，但当前仓库环境只对 `app.galileo.ai` 做过完整在线验收。因此以后切换 Console 时不应先删除 workaround 或修改镜像；先修改 `kup.conf`，运行 `./kup --galileo-only` 让 ConfigMap/Secret/Pod 收敛，再运行脚本并确认启动横幅显示预期的 Console、API backend 和 `Trace ingest: SDK OTLP`。若新后端或未来 SDK 改变 Dataset/Experiment 合约，再仅调整非 legacy 分支并重新验收；不要让 legacy workaround 无条件运行在新后端。

排查时先区分数据层级：

* Dataset 已存在时，UI 中当前保存的行和 Ground Truth 是唯一权威来源；本地默认 6 行只用于首次创建。
* 根 Trace 的 Ground Truth/Generated Output 完整但 Ground Truth Eval 尚无结果，先确认 Evaluator 已绑定；Judge 是异步的，单行失败可以在 UI Recompute，不应重跑 Agent。
* 根级 Token/Cost 为空但 LLM 子 Span 已有 Token，说明 Agent 和 Callback 数据没有丢失，问题位于后端的模型定价或根级聚合；不要重复上传 Trace，也不要手工回填 Cost。
* 脚本只有在 Dataset 字段、generated output、子 Span、成功 LLM token usage 以及每条根 Trace 的 Cost/Tokens/Latency 都读回完整后才打印 `Experiment submitted successfully`。若它以非零状态退出，Experiment 和已采集数据仍保留，应根据打印的 URL 检查，而不是删除后盲目重跑。

### Terraform credential error

确认 `kup.conf` 中 RAM User AccessKey ID/Secret 正确、未过期且权限覆盖 ACK、ECS、VPC、NAT/SLB。Secret 无法找回时创建新 Key。不要把值贴入 issue 或日志。

### Provider download error

确认 Mac 能访问 Terraform Registry，然后重试 `./kup`。代理环境需让 Terraform/Go 下载使用同一代理；不要提交 `.terraform/`。

### InvalidAccountStatus.NotEnoughBalance

这是 Alibaba Cloud 账号级计费拒绝，不是 Terraform、ACK、实例规格或 Galileo 配置错误。官方 ECS 错误码说明，订购按量付费产品时账户可用余额通常不得低于 100 元；先在费用与成本控制台补足可用余额、结清欠费并确认支付方式可用，然后原样重跑 `./kup`。如果账号由代理商管理且返回 `InsufficientBalance.AgentCredit`，应联系渠道伙伴补充额度。

`kup` 会在第一次识别到余额、欠费、支付方式或代理商额度错误时立即停止，不做无意义重试。Terraform state 会保留；如果 VPC、vSwitch 或 ACK 控制面已经创建，下一次运行只继续创建缺失的 Node Pool。降低 Worker 数量或规格不能绕过账号级按量付费门槛，也会破坏本 Demo 的 3 节点和内存基线。如果暂时不准备充值，请运行 `./kiall` 释放已经创建且可能继续计费的资源。

参考：[Alibaba Cloud ECS 公共错误码](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-errorcodes)、[账号充值说明](https://help.aliyun.com/zh/document_detail/324650.html)。

### ACK workers initially NotReady

这是 BYOCNI 在 Cilium 安装前的正常状态。只有 Node 对象未出现或 `.spec.podCIDR` 为空超过脚本超时时间才是错误。查看 ACK Node Pool 事件与 ECS 初始化日志。

### Cilium ImagePullBackOff

中国大陆访问外部 registry 可能受限。检查 Pod events；需要时通过已授权 ACR 订阅/镜像同步或企业允许的加速方案解决，不要改成 Terway chaining，也不要随意替换 Enterprise 镜像。

### Cilium Agent not Ready

检查 `daemonset/cilium` events 和 agent 日志，确认节点 PodCIDR、VPC 路由、`securityContext.privileged`、Kubernetes IPAM 与 native routing CIDR 一致。再次运行 `./kup` 会继续 Helm 收敛。

### BPF LSM not enabled

节点首次启动会通过 `user_data` 用 `grubby` 追加 `bpf` 并安排一次重启。检查节点 cloud-init/journal 中的 `ack-byocni-bpf-lsm` 日志。marker 防止重复修改和 reboot loop；如果内核本身不支持 BPF LSM，应更换受支持的 AliyunLinux3 镜像/规格。

### Timescape ClickHouse Pending or OOM

查看 Pod events 与节点 allocatable memory。基线 ClickHouse 请求 4 GiB 且使用 ephemeral storage；不要创建 PVC。默认 `ecs.e-c1m2.xlarge` 为此预留空间。如区域库存不足，选择同区域可用、至少 8 GiB 内存的等效实例。

### Hubble Enterprise to Timescape push error

确认 `hubble-timescape-ingester` endpoints 非空，并检查 Hubble Enterprise fluentd 日志。目标应为 `http://hubble-timescape-ingester.kube-system.svc.cluster.local:4260/push`；不要加入 Integrated Timescape 的 `k8sImporter` values。

### Hubble UI cannot access Timescape

确认 `hubble-ui`、`hubble-relay`、`hubble-timescape` Service 都有 ready endpoints。UI 的 Timescape 地址应为 `hubble-timescape.kube-system.svc.cluster.local`，Relay 地址应为 `hubble-relay.kube-system.svc.cluster.local`。

### Tetragon BTF/LSM issue

确认 `/sys/kernel/btf/vmlinux` 存在，`/sys/kernel/security/lsm` 包含 `bpf`，运行时是 containerd 且 socket 位于 `/run/containerd/containerd.sock`。检查 Tetragon Agent 日志中的 verifier、BTF、LSM 或 permission 错误。

### Alibaba image pull issue

mini-boutique 与 testcurl 已使用 Alibaba Registry 镜像。若仍失败，检查目标 registry 的区域连通、镜像 tag 与 ACK 节点 NAT 出口；不要默认改用 AWS Demo 的 quay.io workload。

### Galileo ImagePullBackOff

确认 `GALILEO_IMAGE_REF` 是 `GALILEO_REGISTRY_SERVER` 下的完整 `@sha256:` immutable reference，并确认 ACR pull username/password 有目标 repository 权限。`kup` 每次都会重建 `galileo-registry-pull` Secret，但不会创建 ACR instance、namespace 或 repository，也不会回退到 `latest`。

### Galileo model, Pinecone, or Splunk AO check fails

`kup` 会在应用 Pod 内运行上游 `pod_network_smoke.py`。模型检查要求 HTTPS `/models` 可认证访问且返回精确 `GALILEO_APP_MODEL_NAME`；Pinecone 检查要求隔离 index/namespace 对 Orbit 查询至少返回一个 hit；Splunk AO console 必须能建立 HTTPS 连接。修复 `kup.conf` 中对应 endpoint/key 或外部服务状态后运行 `./kup --galileo-only`；只有平台组件也需要重新收敛时才运行完整的 `./kup`，不要跳过该硬检查。

### Galileo prompt switch times out

先按上文导出三个显式集群变量，再运行 `./scripts/switch_prompt.sh status` 比较 ConfigMap、挂载文件和 resolver。确认 Deployment 包含 `/etc/banking-prompt` projected ConfigMap volume；旧部署缺少挂载时，上游脚本会兼容性滚动应用 Pod，或可重新运行 `./kup`。正常投影可能需要接近 kubelet 同步周期；`GALILEO_PROMPT_SYNC_TIMEOUT_SEC` 只影响 `kup` 的最终复核，不改变上游切换脚本的等待策略。

### Interrupted kup

保留 Terraform state、kubeconfig 与 `runtime/`，修复中断原因后再次运行 `./kup`。不要手工新建第二套 ACK/VPC。

### Interrupted kiall

不要删除 state。确认上一次 Terraform 操作已停止后再次运行 `./kiall`。脚本只会重试当前 state 的 destroy；失败时不会执行激进清理。

Cloud Shell 仅可在极端情况下作为 Alibaba 侧诊断工具，不属于正常 create/destroy 流程，也不用于手工复制 kubeconfig。

## Roadmap / Deferred Features

以下功能故意不属于 baseline `kup`：

- Observability：kube-prometheus-stack、Grafana、Cilium/Hubble/Tetragon dashboards。
- Application demo：OpenTelemetry Demo。Alibaba Cloud Internet/image accessibility requires a separately verified deployment strategy.
- Egress Gateway：Egress Gateway、HA、external echo/remote outpost 与 failover demo。
- Splunk：Universal Forwarder、Tetragon/Alert 到 Splunk；不会复制 AWS SSM implementation。
- Security attack demo：Vulhub、Shiro 1.2.4、reverse shell、brute-force target 与其他 victim workload。Deferred intentionally; not part of baseline kup.
- Advanced Tetragon：custom Java base64 pipe-to-shell policy、throughput policy、FIM、filesystem SCA、Application Model 与 advanced enforcement。
- AWS-specific：EKS ENI IPAM、AWS SSM、EC2 Security Group 自动配置、CloudFormation cleanup、AWS remote-outpost EC2。

## Cost and security

`destroy means destroy`：Terraform 管理 ACK、Worker、VPC、vSwitch，以及 ACK 创建的 NAT/公网 API 依赖；`kiall` 通过同一 state 删除它们，Galileo namespace 也随 ACK 集群一起消失。Timescape 使用 ephemeral Lite，不创建 PVC；Hubble UI 与 Galileo 都使用 ClusterIP。运行 Demo 会产生 Alibaba Cloud 费用，调用应用模型、Pinecone 与 Splunk AO 还可能产生各服务侧用量或费用；不使用时执行 `./kiall`。

本仓库用于内部演示与自动化实验。使用 Isovalent Enterprise chart 与镜像时遵守相应 entitlement、许可与组织安全要求。
