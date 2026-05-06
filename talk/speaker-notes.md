# Speaker Notes: "From Web Apps to AI — What Changes and What Doesn't"

---

## SLIDE 1 — Title

> No notes. Let the title sit for a beat.

---

## SLIDE 2 — Who this talk is for

This talk is for people like me a couple years ago — platform engineers who are comfortable running serving and batch workloads on Kubernetes and are now being asked to support AI. Maybe your team just got a request to "set up GPU infrastructure" and you're trying to figure out how much of what you know still applies.

The answer is: a lot of it. But not all of it. And I think it's important to be specific about which parts transfer and which parts require genuinely new expertise. That's what this talk is about.

---

## SLIDE 3 — AI workloads through a platform lens

Let's start by mapping AI workloads to things we already understand.

Inference is a form of serving. A client sends a request, a server does some compute, and returns a response. Latency matters. Availability matters. You need to route, scale, and handle overload.

Training is a form of batch. A job claims resources, runs for a while, and completes. Throughput matters more than latency. You need scheduling, priority, and the ability to preempt when something more important comes along.

The resource is the GPU, and what makes it different isn't that it's exotic — it's that it's expensive and scarce. When a single resource unit costs 10 to 100x what a CPU core costs, you care a lot more about utilization, priority, and waste.

Some of the patterns you use for serving and batch carry right over. Some need real adaptation. Let's look at a concrete platform and see where the lines fall.

---

## SLIDE 4 — The demo platform

Here's what we're working with. Three GKE clusters. A management cluster that hosts the cross-region gateway — no GPUs, just routing. Two worker clusters in different regions, each with 8 NVIDIA RTX PRO 6000 Blackwell GPUs.

We're serving Llama-3.1-8B-Instruct with a LoRA fine-tune on top. The stack underneath is a mix of general Kubernetes tooling — Gateway API, Kueue, HPA — and AI-specific extensions like the Endpoint Picker with inference-aware scoring plugins.

I want to walk through three platform problems and show you, for each one, what's familiar territory and where new complexity shows up.

---

## SLIDE 5 — Three platform problems

Three problems. You've solved versions of all of these before.

First: multi-cluster routing. How do you send traffic to the right place? You've done this for web traffic with health checks and load balancing.

Second: resource contention. What happens when your serving tier needs capacity that's currently occupied by batch work? You've dealt with this on Black Friday when checkout needed nodes and the nightly ETL had to wait.

Third: request prioritization. When the backend is overloaded, who gets served first? You've configured this in API gateways with rate tiers.

The solutions for AI workloads have real overlap with these traditional approaches. They also have real differences. Let me show you both.

---

## SLIDE 6 — Problem 1: Multi-cluster traffic routing

Here's the backend policy that controls cross-region routing. GCLB uses custom metrics balancing — when KV-cache utilization in east1 crosses 60%, it starts ramping traffic to west3.

What's familiar: the routing mechanism itself. Custom metrics balancing mode is workload-agnostic. You could swap `kv-cache` for `request-latency-p99` and use this exact configuration for a web application. The GCLB doesn't know or care that it's routing inference traffic.

What's different: the metric. KV-cache utilization measures how much GPU memory the model is using for in-flight request state. Choosing this metric, and choosing 60% as the threshold, requires understanding how LLM serving works — how the KV-cache fills during decode, how it relates to request throughput, and at what point a cluster starts degrading. You wouldn't arrive at these numbers without understanding the workload.

So the mechanism transfers. The tuning doesn't.

---

## SLIDE 7 — Three-tier routing deep dive

Let me show you the full path a request takes through the system, because the three tiers illustrate the spectrum from general to AI-specific really well.

Tier 1 is GCLB picking a cluster. Fully general. This is metric-based traffic steering that works for any backend.

Tier 2 is the EPP's flow control. The pattern is general — it's priority queuing at L7, same thing you'd want in front of any overloaded API. But the saturation signals are AI-specific. The EPP watches KV-cache utilization and model server queue depth to decide when to engage. Those signals reflect GPU memory pressure and continuous batching behavior, which you'd need to learn about.

Tier 3 is pod selection. This is purpose-built for LLM serving. The scoring plugins evaluate KV-cache utilization per pod, prefix-cache hit rates, and queue depth. Prefix-cache affinity in particular — routing a request to the pod that already has similar context in its cache — has no analog in traditional web serving.

So you get a gradient: fully transferable at the top, fully new at the bottom. Knowing where you sit on that gradient helps you plan what your team needs to learn.

---

## SLIDE 8 — Problem 2: Priority preemption

Kueue manages GPU quota. Each worker cluster has a ClusterQueue with 8 GPUs. Three priority classes control preemption.

What's familiar: everything about Kueue's model. The ClusterQueue, the preemption policy, the priority classes — this all works identically for CPU workloads. Change `nvidia.com/gpu` to `cpu` and adjust the quota number and the behavior is the same. Kueue is resource-agnostic by design.

What's different: the cost of getting it wrong. When you preempt a CPU workload, it typically restarts in seconds. When you preempt a training job, you might be throwing away hours of computation — unless you've checkpointed, which adds its own complexity. When you preempt an inference pod, it takes minutes to come back — the model has to download and load onto the GPU.

This changes how you set priorities and thresholds. You need wider gaps between priority levels because the recovery cost of a bad preemption decision is high. And you need to think about whether preempted work can actually reschedule somewhere else, because if it can't, you've just killed a job for nothing.

The mechanism is the same. The operational stakes are higher.

---

## SLIDE 9 — MultiKueue: cross-cluster job placement

When a training job needs 2 GPUs and east1 is full, MultiKueue dispatches it to west3. That's the basic behavior, and it works the same way you'd distribute any batch job across clusters.

We built a custom dispatcher to be smarter about placement. It scores each cluster by the cost of admitting a workload there — factoring in how many existing workloads would need to be evicted, their priority weights, and whether they're running or still pending.

The scoring algorithm itself is resource-agnostic. It operates on numeric resource counts and priority values. You could use the same approach to place Spark jobs or CI builds across clusters.

But the reason we needed a custom dispatcher is AI-specific. The default Kueue dispatcher doesn't account for eviction cost — it just finds a cluster with space. That's fine when preemption is cheap, but when evicting a running training job wastes hours of GPU time, you want to pick the cluster that causes the least damage. The sensitivity to preemption cost is what makes this different from traditional batch scheduling.

---

## SLIDE 10 — Problem 3: Request-level priority under saturation

When the system saturates — KV-cache above 90% or queue depth above 100 — the EPP stops forwarding requests and starts queuing them by priority.

Two headers control this. The inference objective maps to a priority: production gets 100, batch gets negative 10. The fairness ID provides per-tenant fair queuing within a priority band.

What's familiar: this is the same pattern as API gateway rate limiting. Premium tier gets served first, free tier waits, and within each tier nobody starves because of fair scheduling. You've configured this before.

What's different: how saturation is detected. In a traditional web stack, you might trigger priority queuing on connection pool exhaustion or response time degradation. Here, the EPP watches KV-cache utilization and model server queue depth. These signals reflect GPU memory pressure and the LLM's internal continuous batching behavior. Tuning the thresholds — 90% KV-cache, queue depth of 100 — requires understanding how vLLM manages its batch scheduler and when adding more requests starts degrading time-per-output-token for requests already in flight.

The priority queuing pattern transfers. The capacity signals that drive it are domain-specific.

---

## SLIDE 11 — Scale-to-zero spillover

West3 is our spillover region. When it's idle, it scales to zero — zero replicas, zero GPU cost. The HPA watches the EPP's flow control queue depth. When requests start queuing, the HPA fires and scales up aggressively.

What's familiar: scale-from-zero on a queue depth metric. Same pattern as KEDA scaling consumers from zero when an SQS or Pub/Sub queue grows. The HPA spec is completely standard.

What's different: the cold start. Our startup probe allows 10 minutes. The model needs to download — potentially gigabytes — and load into GPU memory. Compare that to a web app container that starts in under a second.

This changes the entire scaling strategy. We need aggressive scale-up — 4 pods every 15 seconds, zero stabilization window — because every second of delay means more requests queuing in the EPP. And the EPP has to be designed to buffer HTTP connections for minutes without timing out or dropping them. In a traditional stack you wouldn't need your proxy to hold connections for 5 minutes while the backend cold-starts.

This is one of the places where AI workloads aren't just "the same but with GPUs." The cold start problem is qualitatively different and it ripples through your autoscaling, your preemption policies, and your client timeout configurations.

---

## SLIDE 12 — DEMO TIME

Let me show you this running. Three acts.

Act one: I submit training jobs and MultiKueue distributes them across clusters as capacity allows.

Act two: I generate inference load. The HPA scales up, GPUs fill, and Kueue preempts a training job to make room for inference. The preempted job gets rescheduled to the other cluster.

Act three: load continues until the EPP saturates. Flow control engages. Production traffic keeps moving while batch traffic queues.

Watch the dashboard — it shows cluster state, scheduling decisions, and EPP flow control metrics in real time.

---

## SLIDES 13-15 — Demo

**Act 1 narration:**

Watch the Kueue panel. I'm submitting three training jobs, each needs 2 GPUs. First two land on east1 — it had 4 free GPUs. Third one can't fit. East1 is at 8 of 8. MultiKueue picks west3 automatically.

This is similar to how you'd distribute batch jobs across clusters. The scheduling logic is general-purpose. The resource happens to be GPUs, but Kueue would handle CPU quotas the same way.

**Act 2 narration:**

Now I'm turning on inference load. Watch the KV-cache bars — that's a metric unique to LLM serving. As they climb past 45%, the HPA starts scaling. 2 pods, 3, 4. But we only have 8 GPUs and training is using 4.

Here's the preemption. Kueue sees the pending inference pod at priority 1000, sees the training job at priority 100, and evicts it. The inference pod gets the GPU.

Notice the recovery time — it takes the new inference pod a few minutes to load the model and start serving. In a CPU world, that pod would be ready in seconds. This is why getting the preemption thresholds right matters more here.

Now watch — within 30 seconds, MultiKueue reschedules the evicted training job to west3 where there's room. The job isn't lost, just moved.

**Act 3 narration:**

Look at the EPP flow control panel. Queue depth is climbing. The saturation detector has tripped — KV-cache is above 90%.

Production requests at priority 100 are flowing through with minimal delay. Batch requests at negative 10 are queuing up. Some are hitting the 30-second TTL and getting shed.

The priority queuing pattern here works the same as any API gateway under load. The part that's new is the saturation detection — it's looking at GPU-specific signals to know when to engage.

---

## SLIDE 16 — What's genuinely new in AI platforms

Let me be specific about the areas that require new expertise. These aren't slight variations on existing patterns — they're genuinely new.

KV-cache as a routing signal. LLMs maintain per-request state in GPU memory, and it's the primary capacity constraint. Routing and scaling based on this metric is central to running inference well, and there's no direct analog in web serving.

Prefix-cache affinity. When you route a request to the pod that already has similar context cached, you skip expensive prefill computation. This is a routing optimization that's unique to transformer models. Getting it right can significantly reduce latency and cost.

LoRA adapter hot-swapping. We can load and unload fine-tuned model variants at runtime. This is powerful — you can serve hundreds of specialized models from a single base deployment — but it adds operational complexity around adapter lifecycle, memory management, and version coordination.

Multi-minute cold starts. When a pod starts, it downloads gigabytes of model weights and loads them into GPU VRAM. This isn't a problem you can solve with faster container pulls. It fundamentally changes autoscaling strategy, preemption cost calculations, and drain behavior.

GPU memory management. Shared memory mounts, CUDA allocator configuration, device plugins, driver compatibility. This is real operational surface area with its own failure modes and debugging tools.

Continuous batching. The model server interleaves decode steps across concurrent requests inside the GPU. Scheduling happens at two levels — the platform layer and inside the model server — and they interact in ways that aren't obvious until you've debugged them.

None of this should be hand-waved away. It's real complexity, and your team needs time and investment to learn it.

---

## SLIDE 17 — What transfers directly

Now for the other side. These components work the same way for AI workloads as they do for everything else.

Gateway API with custom metrics balancing — workload-agnostic. The mechanism doesn't know what it's routing.

Kueue and MultiKueue — resource-agnostic. Works with GPUs, CPUs, TPUs, any extended resource.

HPA on custom metrics — metric-agnostic. The HPA doesn't care whether the metric comes from a model server or a web server.

PriorityClass with preemption — built into Kubernetes since 1.14. Not AI-specific at all.

EPP flow control — packaged as part of the inference extension, but the pattern of priority queuing at L7 applies to any saturated API.

If you're not already using Kueue for your batch workloads or custom-metric Gateway routing for your web apps, these are worth evaluating independently of AI. We built this for inference, but the tools are useful for the workloads you're already running.

---

## SLIDE 18 — Where you need new skills

Let me be concrete about the learning investment.

GPU device management. Device plugins, CUDA drivers, shared memory configuration, driver version compatibility. This is mostly operational — not conceptually hard, but it's new plumbing with its own failure modes.

Model serving internals. KV-cache, continuous batching, prefix caching, LoRA adapters, attention backends. This is where you need real depth if you're going to debug production issues and tune performance. You can't treat the model server as a black box.

Capacity planning. GPU resources are coarse-grained — one GPU is a big allocation, not a millicore. Cold starts are measured in minutes. This changes your scaling math, your bin-packing strategy, and your spare capacity calculations.

Cost management. GPU-hours are expensive. Idle GPUs are much more costly than idle CPUs. Getting utilization right matters more, and the tools for measuring and optimizing it are still maturing.

Observability. Familiar tools — Prometheus, Grafana — but new metrics. KV-cache utilization, time-per-output-token, time-to-first-token, batch utilization. You need to learn what these mean and what "healthy" looks like.

---

## SLIDE 19 — Practical takeaways

Four things to take away.

One. Audit your existing tools. If you're not already using Kueue for quota management, or custom-metric routing in your Gateway, consider adopting them for your current workloads first. You'll build familiarity that transfers directly when you add GPU workloads.

Two. Invest in understanding model serving. The platform layer transfers well. The workload layer — KV-cache behavior, batching dynamics, LoRA lifecycle — requires genuine new learning. Don't underestimate it, and give your team time to build that expertise.

Three. Respect the cost of preemption. GPU cold starts change the math on everything. A preemption policy that works fine when pods restart in 200 milliseconds needs serious rethinking when recovery takes 5 minutes and you might be throwing away hours of training progress.

Four. The tools are converging. Kueue, Gateway API Inference Extension, and MultiKueue are all upstream Kubernetes projects. The ecosystem is building toward a unified platform layer for all workload types — not separate stacks for AI and everything else.

---

## SLIDE 20 — Resources / links

> Keep this slide up during Q&A.

Thank you.
