import Foundation

struct UsageData: Codable {
    let generatedAt: String
    let auth: AuthByProvider
    let claude: Provider
    let codex: Provider
    let limits: Limits?
    let services: Services
    let errors: [String]
    let aggregations: Aggregations

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        auth = try c.decodeIfPresent(AuthByProvider.self, forKey: .auth) ?? AuthByProvider()
        claude = try c.decodeIfPresent(Provider.self, forKey: .claude) ?? Provider()
        codex = try c.decodeIfPresent(Provider.self, forKey: .codex) ?? Provider()
        limits = try c.decodeIfPresent(Limits.self, forKey: .limits)
        services = try c.decodeIfPresent(Services.self, forKey: .services) ?? Services()
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        aggregations = try c.decodeIfPresent(Aggregations.self, forKey: .aggregations) ?? Aggregations()
    }
}

struct ProviderAuth: Codable {
    let loggedIn: Bool
    let email: String?
    let subscriptionType: String?
    let method: String?
    let account: String?

    init(loggedIn: Bool = false, email: String? = nil, subscriptionType: String? = nil, method: String? = nil, account: String? = nil) {
        self.loggedIn = loggedIn
        self.email = email
        self.subscriptionType = subscriptionType
        self.method = method
        self.account = account
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loggedIn = try c.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
        email = try c.decodeIfPresent(String.self, forKey: .email)
        subscriptionType = try c.decodeIfPresent(String.self, forKey: .subscriptionType)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
}

struct AuthByProvider: Codable {
    let claude: ProviderAuth
    let codex: ProviderAuth

    init(claude: ProviderAuth = ProviderAuth(), codex: ProviderAuth = ProviderAuth()) {
        self.claude = claude
        self.codex = codex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = try c.decodeIfPresent(ProviderAuth.self, forKey: .claude) ?? ProviderAuth()
        codex = try c.decodeIfPresent(ProviderAuth.self, forKey: .codex) ?? ProviderAuth()
    }
}

struct PeriodRow: Codable {
    let period: String?
    let totalTokens: Int
    let totalCost: Double
    let inputTokens: Int
    let cacheTokens: Int
    let outputTokens: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decodeIfPresent(String.self, forKey: .period)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cacheTokens = try c.decodeIfPresent(Int.self, forKey: .cacheTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    }
}

struct Provider: Codable {
    let totals: ProviderTotals
    let dailyData: [PeriodRow]?
    let weeklyData: [PeriodRow]?
    let monthlyData: [PeriodRow]?

    enum CodingKeys: String, CodingKey {
        case totals
        case dailyData
        case weeklyData
        case monthlyData
    }

    init(totals: ProviderTotals = ProviderTotals(), dailyData: [PeriodRow]? = nil, weeklyData: [PeriodRow]? = nil, monthlyData: [PeriodRow]? = nil) {
        self.totals = totals
        self.dailyData = dailyData
        self.weeklyData = weeklyData
        self.monthlyData = monthlyData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totals = try container.decodeIfPresent(ProviderTotals.self, forKey: .totals) ?? ProviderTotals()
        dailyData = try container.decodeIfPresent([PeriodRow].self, forKey: .dailyData)
        weeklyData = try container.decodeIfPresent([PeriodRow].self, forKey: .weeklyData)
        monthlyData = try container.decodeIfPresent([PeriodRow].self, forKey: .monthlyData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totals, forKey: .totals)
        try container.encodeIfPresent(dailyData, forKey: .dailyData)
        try container.encodeIfPresent(weeklyData, forKey: .weeklyData)
        try container.encodeIfPresent(monthlyData, forKey: .monthlyData)
    }
}

struct ProviderTotals: Codable {
    let totalTokens: Int
    let totalCost: Double
    let inputTokens: Int
    let cacheTokens: Int
    let outputTokens: Int

    init(totalTokens: Int = 0, totalCost: Double = 0, inputTokens: Int = 0, cacheTokens: Int = 0, outputTokens: Int = 0) {
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.inputTokens = inputTokens
        self.cacheTokens = cacheTokens
        self.outputTokens = outputTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cacheTokens = try c.decodeIfPresent(Int.self, forKey: .cacheTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    }
}

struct Limits: Codable {
    let session: LimitDetail?
    let weekly: LimitDetail?
    let fetchedAt: String?
    /// Why these numbers stopped moving: "auth_expired", "no_token", "failed".
    /// Absent when the last fetch succeeded.
    let stale: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decodeIfPresent(LimitDetail.self, forKey: .session)
        weekly = try c.decodeIfPresent(LimitDetail.self, forKey: .weekly)
        fetchedAt = try c.decodeIfPresent(String.self, forKey: .fetchedAt)
        stale = try c.decodeIfPresent(String.self, forKey: .stale)
    }
}

struct LimitDetail: Codable {
    let percent: Int
    let resetsAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decodeIfPresent(Int.self, forKey: .percent) ?? 0
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

struct Services: Codable {
    let anthropic: ServiceStatus
    let openai: ServiceStatus

    init(anthropic: ServiceStatus = ServiceStatus(), openai: ServiceStatus = ServiceStatus()) {
        self.anthropic = anthropic
        self.openai = openai
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anthropic = try c.decodeIfPresent(ServiceStatus.self, forKey: .anthropic) ?? ServiceStatus()
        openai = try c.decodeIfPresent(ServiceStatus.self, forKey: .openai) ?? ServiceStatus()
    }
}

struct ServiceStatus: Codable {
    let status: StatusDetail
    let components: [ServiceComponent]?
    let incidents: [ServiceIncident]?

    enum CodingKeys: String, CodingKey {
        case status
        case components
        case incidents
    }

    init(status: StatusDetail = StatusDetail(), components: [ServiceComponent]? = nil, incidents: [ServiceIncident]? = nil) {
        self.status = status
        self.components = components
        self.incidents = incidents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(StatusDetail.self, forKey: .status) ?? StatusDetail()
        components = try container.decodeIfPresent([ServiceComponent].self, forKey: .components)
        incidents = try container.decodeIfPresent([ServiceIncident].self, forKey: .incidents)
    }
}

struct ServiceComponent: Codable {
    let id: String
    let name: String
    let status: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    }
}

struct ServiceIncident: Codable {
    let name: String
    let status: String
    let impact: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        impact = try c.decodeIfPresent(String.self, forKey: .impact) ?? ""
    }
}

struct StatusDetail: Codable {
    let indicator: String
    let description: String

    init(indicator: String = "unknown", description: String = "") {
        self.indicator = indicator
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        indicator = try c.decodeIfPresent(String.self, forKey: .indicator) ?? "unknown"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

struct Aggregations: Codable {
    let byDayOfWeek: [DayData]
    let byModel: [ModelData]
    let currentWeekByModel: [ModelData]
    let weeklyHistory: [WeekData]
    let monthlyHistory: [MonthData]?
    let currentWeekByDayOfWeek: [DayData]?

    init(byDayOfWeek: [DayData] = [], byModel: [ModelData] = [], currentWeekByModel: [ModelData] = [], weeklyHistory: [WeekData] = [], monthlyHistory: [MonthData]? = nil, currentWeekByDayOfWeek: [DayData]? = nil) {
        self.byDayOfWeek = byDayOfWeek
        self.byModel = byModel
        self.currentWeekByModel = currentWeekByModel
        self.weeklyHistory = weeklyHistory
        self.monthlyHistory = monthlyHistory
        self.currentWeekByDayOfWeek = currentWeekByDayOfWeek
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byDayOfWeek = try c.decodeIfPresent([DayData].self, forKey: .byDayOfWeek) ?? []
        byModel = try c.decodeIfPresent([ModelData].self, forKey: .byModel) ?? []
        currentWeekByModel = try c.decodeIfPresent([ModelData].self, forKey: .currentWeekByModel) ?? []
        weeklyHistory = try c.decodeIfPresent([WeekData].self, forKey: .weeklyHistory) ?? []
        monthlyHistory = try c.decodeIfPresent([MonthData].self, forKey: .monthlyHistory)
        currentWeekByDayOfWeek = try c.decodeIfPresent([DayData].self, forKey: .currentWeekByDayOfWeek)
    }
}

struct DayData: Codable {
    let name: String
    let tokens: Int
    let cost: Double
    let entries: Int

    init(name: String = "", tokens: Int = 0, cost: Double = 0, entries: Int = 0) {
        self.name = name
        self.tokens = tokens
        self.cost = cost
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        entries = try c.decodeIfPresent(Int.self, forKey: .entries) ?? 0
    }
}

struct ModelData: Codable {
    let model: String
    let tokens: Int
    let cost: Double

    init(model: String = "", tokens: Int = 0, cost: Double = 0) {
        self.model = model
        self.tokens = tokens
        self.cost = cost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
    }
}

struct WeekData: Codable {
    let week: String
    let tokens: Int
    let cost: Double
    let inputTokens: Int
    let cacheTokens: Int
    let outputTokens: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = try c.decode(String.self, forKey: .week)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cacheTokens = try c.decodeIfPresent(Int.self, forKey: .cacheTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    }
}

struct MonthData: Codable {
    let month: String
    let tokens: Int
    let cost: Double
    let inputTokens: Int
    let cacheTokens: Int
    let outputTokens: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cacheTokens = try c.decodeIfPresent(Int.self, forKey: .cacheTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    }
}

struct Config: Codable {
    var activeProvider: String = "claude"
    var barMetric: String = "weekly"
    var workDays: Int = 5
    var refreshMinutes: Int = 5
    var barStyle: String = "percentage"
    var language: String = "cs"
    var historyPeriod: String = "week"
    var notifyServices: [String] = []

    init(activeProvider: String = "claude", barMetric: String = "weekly", workDays: Int = 5,
         refreshMinutes: Int = 5, barStyle: String = "percentage", language: String = "cs", historyPeriod: String = "week", notifyServices: [String] = []) {
        self.activeProvider = activeProvider
        self.barMetric = barMetric
        self.workDays = workDays
        self.refreshMinutes = refreshMinutes
        self.barStyle = barStyle
        self.language = language
        self.historyPeriod = historyPeriod
        self.notifyServices = notifyServices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeProvider = try container.decodeIfPresent(String.self, forKey: .activeProvider) ?? "claude"
        barMetric = try container.decodeIfPresent(String.self, forKey: .barMetric) ?? "weekly"
        workDays = try container.decodeIfPresent(Int.self, forKey: .workDays) ?? 5
        refreshMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 5
        barStyle = try container.decodeIfPresent(String.self, forKey: .barStyle) ?? "percentage"
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "cs"
        historyPeriod = try container.decodeIfPresent(String.self, forKey: .historyPeriod) ?? "week"
        notifyServices = try container.decodeIfPresent([String].self, forKey: .notifyServices) ?? []
    }
}
