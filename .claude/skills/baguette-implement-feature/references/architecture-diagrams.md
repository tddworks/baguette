# Architecture Diagram Patterns

ASCII diagrams for documenting feature architecture before implementation.

## Table of Contents

- [Layered Architecture](#layered-architecture)
- [Data Flow Diagrams](#data-flow-diagrams)
- [Sequence Diagrams](#sequence-diagrams)
- [Component Interaction Tables](#component-interaction-tables)

---

## Layered Architecture

### Three-Layer Pattern (Standard)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        FEATURE: [Feature Name]                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  EXTERNAL              INFRASTRUCTURE           DOMAIN               │
│  ┌─────────────┐       ┌─────────────────┐     ┌─────────────────┐  │
│  │  [Source]   │──────▶│  [Repository/   │────▶│  [Model]        │  │
│  │  (API/DB)   │       │   Client]       │     │  (value types)  │  │
│  └─────────────┘       └─────────────────┘     └─────────────────┘  │
│                                                        │             │
│                                                        ▼             │
│                                              ┌─────────────────┐     │
│                                              │  [Service]      │     │
│                                              │  (actor)        │     │
│                                              └─────────────────┘     │
│                                                       │              │
│                                                       ▼              │
│                        ┌───────────────────────────────────────┐    │
│                        │  APP LAYER                             │    │
│                        │  ┌─────────────────────────────────┐   │    │
│                        │  │  [Views/Registration]            │   │    │
│                        │  └─────────────────────────────────┘   │    │
│                        └───────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

### Full System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Swift App System                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                         Domain Layer                                │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │ │
│  │  │ Order        │  │ User         │  │ OrderManager (actor)     │  │ │
│  │  │ OrderStatus  │  │ Product      │  │ CartService              │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                    ▲                                     │
│                                    │ implements                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                      Infrastructure Layer                           │ │
│  │  ┌────────────────────────────────────────────────────────────┐    │ │
│  │  │                      Repositories                           │    │ │
│  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐   │    │ │
│  │  │  │ Order    │ │ User     │ │ Product  │ │ [NewRepo]    │   │    │ │
│  │  │  │ Repo     │ │ Repo     │ │ Repo     │ │              │   │    │ │
│  │  │  └──────────┘ └──────────┘ └──────────┘ └──────────────┘   │    │ │
│  │  └────────────────────────────────────────────────────────────┘    │ │
│  │                                                                     │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │ │
│  │  │ NetworkClient│  │ DatabaseClient│  │ NotificationService     │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                    ▲                                     │
│                                    │ uses                                │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                          App Layer                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │ │
│  │  │ AppState     │  │ Views        │  │ App Entry Point          │  │ │
│  │  │ (@Observable)│  │              │  │ (registration)           │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow Diagrams

### Repository Data Flow

```
┌───────────┐     ┌───────────┐     ┌───────────┐     ┌───────────┐
│  API/DB   │────▶│ Repository│────▶│  Mapper   │────▶│  Domain   │
│  Response │     │  Fetch    │     │  Logic    │     │  Model    │
└───────────┘     └───────────┘     └───────────┘     └───────────┘
     Raw               Fetch            Parse            Domain
     Data              Data             Data             Model
```

### Service Orchestration Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SERVICE FLOW                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  View ──▶ Service (actor) ──▶ Repository.fetch() ──▶ API/DB         │
│               │                                        │            │
│               │                                        ▼            │
│               │                              ┌─────────────────┐   │
│               │                              │ External Call   │   │
│               │                              └─────────────────┘   │
│               │                                        │            │
│               │                                        ▼            │
│               │                              ┌─────────────────┐   │
│               │                              │ Parse Response  │   │
│               │                              └─────────────────┘   │
│               │                                        │            │
│               ▼                                        ▼            │
│       ┌─────────────────┐                   ┌─────────────────┐     │
│       │ Update State    │◀──────────────────│ Domain Model    │     │
│       │ (notify views)  │                   │ (returned)      │     │
│       └─────────────────┘                   └─────────────────┘     │
│               │                                                     │
│               ▼                                                     │
│       ┌─────────────────┐                                           │
│       │ SwiftUI Updates │                                           │
│       └─────────────────┘                                           │
└─────────────────────────────────────────────────────────────────────┘
```

### Error Handling Flow

```
┌─────────┐     ┌───────────┐     ┌─────────────┐     ┌──────────────┐
│  Repo   │────▶│ Try Fetch │────▶│   Success   │────▶│ Return Data  │
└─────────┘     └───────────┘     └─────────────┘     └──────────────┘
                      │
                      ▼ (failure)
               ┌─────────────┐     ┌─────────────────┐
               │ Catch Error │────▶│ Map to Domain   │
               └─────────────┘     │ Error           │
                                   └─────────────────┘
                                          │
                                          ▼
                                   ┌─────────────────┐
                                   │ Service handles │
                                   │ or propagates   │
                                   └─────────────────┘
```

---

## Sequence Diagrams

### User Action Flow

```
User          View          Service          Repository        API
 │              │               │                │               │
 │──tap()──────▶│               │                │               │
 │              │──action()────▶│                │               │
 │              │               │──fetch()──────▶│               │
 │              │               │                │──request()───▶│
 │              │               │                │               │
 │              │               │                │◀──response────│
 │              │               │◀──model────────│               │
 │              │               │                │               │
 │              │               │──notify()─────▶│ (if changed)  │
 │◀───UI update─│               │                │               │
 │              │               │                │               │
```

### State Change Notification

```
Repository      Service         @Observable      View
  │                 │               │               │
  │──model─────────▶│               │               │
  │                 │──update()────▶│               │
  │                 │               │               │
  │                 │               │ (state changed)
  │                 │               │──invalidate()─▶│
  │                 │               │               │
  │                 │               │               │──redraw
  │                 │               │               │
```

---

## Component Interaction Tables

### Standard Table Format

```
| Component        | Purpose                 | Inputs           | Outputs         | Dependencies      |
|------------------|-------------------------|------------------|-----------------|-------------------|
| OrderRepository  | Fetches orders from API | OrderId          | Order           | NetworkClient     |
| OrderManager     | Manages order lifecycle | Order, Status    | Updated Order   | OrderRepository   |
| OrderMapper      | Converts DTO to domain  | OrderDTO         | Order           | None              |
```

### Extended Table (for complex features)

```
| Component        | Layer          | Protocol           | Creates/Modifies    | Test File                      |
|------------------|----------------|--------------------|---------------------|--------------------------------|
| APIOrderRepo     | Infrastructure | OrderRepository    | Creates             | APIOrderRepositoryTests.swift  |
| OrderMapper      | Infrastructure | -                  | Creates             | OrderMapperTests.swift         |
| OrderManager     | Domain         | -                  | Manages             | OrderManagerTests.swift        |
| OrderListView    | App            | -                  | Displays            | -                              |
```

### Files to Create/Modify Table

```
| File Path                                       | Action   | Description                          |
|-------------------------------------------------|----------|--------------------------------------|
| Sources/Infrastructure/API/OrderRepository.swift | Create   | Implements OrderRepository protocol  |
| Sources/Domain/Services/OrderManager.swift       | Create   | Actor managing order state           |
| Tests/InfrastructureTests/OrderRepositoryTests.swift | Create | Repository behavior tests       |
| Sources/App/Views/OrderListView.swift            | Create   | SwiftUI view for orders              |
| Sources/App/App.swift                            | Modify   | Register dependencies                |
```

---

## Approval Prompt Template

After presenting the architecture, ask for user approval:

```
## Architecture Review

I've designed the architecture for [Feature Name]:

[Diagram Here]

### Components Summary

| Component | Purpose |
|-----------|---------|
| [Name]    | [Desc]  |

### Files to Create/Modify

- `Sources/.../NewFile.swift` - [Description]
- `Tests/.../NewTests.swift` - [Description]

**Ready to proceed with TDD implementation?**
```

Use AskUserQuestion with:
- "Approve - proceed with implementation"
- "Modify - I have feedback on the design"
