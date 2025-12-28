import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  runApp(const QueueSimApp());
}

// --- Theme Constants (Matched to your HTML) ---
const Color kBgColor = Color(0xFF121212);
const Color kCardBg = Color(0xFF1E1E1E);
const Color kTextColor = Color(0xFFE0E0E0);
const Color kAccentColor = Color(0xFF00FF9D); // Green 'Go'
const Color kSecondaryColor = Color(0xFFFF0055);
const Color kBorderColor = Color(0xFF333333);

class QueueSimApp extends StatelessWidget {
  const QueueSimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Queue Theory Sim',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBgColor,
        fontFamily: 'Consolas',
        // Monospace feel
        colorScheme: const ColorScheme.dark(
          primary: kAccentColor,
          surface: kCardBg,
        ),
        useMaterial3: true,
      ),
      home: const SimulatorPage(),
    );
  }
}

// --- Data Models ---
enum PriorityRule { FIFO, LIFO, SJF }

class Customer {
  final int id;
  final double arrivalTime;
  final double serviceDuration;
  double? startTime;

  Customer({
    required this.id,
    required this.arrivalTime,
    required this.serviceDuration,
  });
}

class Server {
  final int id;
  bool isBusy = false;
  int? customerId;

  Server(this.id);
}

class SimEvent {
  final double time;
  final String type; // 'ARR' or 'DEP'
  final Customer customer;
  final int? serverId;

  SimEvent(this.time, this.type, this.customer, {this.serverId});
}

class TableRowData {
  final String clock;
  final String type;
  final String id;
  final String servers;
  final int qLen;
  final String qStr; // Queue contents
  final String delay;
  final String areaQ;
  final String areaB;

  TableRowData(
    this.clock,
    this.type,
    this.id,
    this.servers,
    this.qLen,
    this.qStr,
    this.delay,
    this.areaQ,
    this.areaB,
  );
}

// --- Main Page ---
class SimulatorPage extends StatefulWidget {
  const SimulatorPage({super.key});

  @override
  State<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends State<SimulatorPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Inputs
  final TextEditingController _cServers = TextEditingController(text: "2");
  final TextEditingController _cLambda = TextEditingController(text: "2.0");
  final TextEditingController _cMu = TextEditingController(text: "1.5");
  final TextEditingController _cMaxTime = TextEditingController(text: "20");
  final TextEditingController _cManualServers = TextEditingController(
    text: "1",
  );
  final TextEditingController _cManualData = TextEditingController(
    text: "1.0, 2.0\n2.0, 1.0\n2.5, 3.0\n4.0, 1.5",
  );
  PriorityRule _priorityRule = PriorityRule.FIFO;

  // Results
  double _resUtil = 0;
  double _resWait = 0;
  double _resLen = 0;
  double _resAreaQ = 0;

  List<FlSpot> _chartData = [];
  List<TableRowData> _tableRows = [];

  // UI State
  bool _hasRun = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  // --- Logic: Random Generator ---
  List<Customer> generateProbabilisticData(
    double lambda,
    double mu,
    double maxTime,
  ) {
    List<Customer> arr = [];
    double t = 0;
    int id = 1;
    final rng = Random();

    while (true) {
      // Inverse Transform Sampling for Exponential Distribution
      double inter = -log(1 - rng.nextDouble()) / lambda;
      t += inter;
      if (t > maxTime) break;
      double dur = -log(1 - rng.nextDouble()) / mu;
      arr.add(Customer(id: id++, arrivalTime: t, serviceDuration: dur));
    }
    return arr;
  }

  List<Customer> parseManualData() {
    List<Customer> arr = [];
    List<String> lines = _cManualData.text.trim().split('\n');
    for (int i = 0; i < lines.length; i++) {
      List<String> parts = lines[i].split(',');
      if (parts.length == 2) {
        try {
          double arrTime = double.parse(parts[0].trim());
          double dur = double.parse(parts[1].trim());
          arr.add(
            Customer(id: i + 1, arrivalTime: arrTime, serviceDuration: dur),
          );
        } catch (e) {
          // Ignore bad lines
        }
      }
    }
    return arr;
  }

  // --- Logic: Simulation Engine ---
  void runSimulation() {
    // 1. Gather Inputs
    List<Customer> arrivalData;
    int numServers;
    double maxTimeVal;

    bool isProbabilistic = _tabController.index == 0;

    try {
      if (isProbabilistic) {
        numServers = int.parse(_cServers.text);
        double lambda = double.parse(_cLambda.text);
        double mu = double.parse(_cMu.text);
        maxTimeVal = double.parse(_cMaxTime.text);
        arrivalData = generateProbabilisticData(lambda, mu, maxTimeVal);
      } else {
        numServers = int.parse(_cManualServers.text);
        maxTimeVal = 99999;
        arrivalData = parseManualData();
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Input Error: $e")));
      return;
    }

    // 2. Initialize
    List<Server> servers = List.generate(numServers, (i) => Server(i + 1));
    List<SimEvent> eventList = arrivalData
        .map((c) => SimEvent(c.arrivalTime, 'ARR', c))
        .toList();

    // Sort initial events
    eventList.sort((a, b) => a.time.compareTo(b.time));

    // Reset loop vars
    double currentTime = 0;
    List<Customer> queue = [];
    List<Customer> completed = [];
    double areaQ = 0;
    double areaB = 0;
    double totalDelay = 0;
    List<FlSpot> historyQ = [const FlSpot(0, 0)];
    List<TableRowData> rows = [];

    // Initial Row
    rows.add(
      TableRowData(
        "0.00",
        "START",
        "-",
        servers.map((s) => "[_]").join(),
        0,
        "[]",
        "0.00",
        "0.00",
        "0.00",
      ),
    );

    // 3. DES Loop
    while (eventList.isNotEmpty) {
      eventList.sort((a, b) => a.time.compareTo(b.time));
      SimEvent evt = eventList.removeAt(0);

      double prevTime = currentTime;
      currentTime = evt.time;

      if (isProbabilistic && currentTime > maxTimeVal) break;

      // Integration
      double dt = currentTime - prevTime;
      int busyCount = servers.where((s) => s.isBusy).length;
      areaQ += queue.length * dt;
      areaB += busyCount * dt;

      // Add a stepped point to chart (step-before)
      historyQ.add(FlSpot(currentTime, queue.length.toDouble()));

      if (evt.type == 'ARR') {
        // Find free server
        int freeServerIdx = servers.indexWhere((s) => !s.isBusy);
        if (freeServerIdx != -1) {
          Server srv = servers[freeServerIdx];
          srv.isBusy = true;
          srv.customerId = evt.customer.id;
          evt.customer.startTime = currentTime;

          double depTime = currentTime + evt.customer.serviceDuration;
          eventList.add(
            SimEvent(depTime, 'DEP', evt.customer, serverId: srv.id),
          );
        } else {
          queue.add(evt.customer);
        }
      } else if (evt.type == 'DEP') {
        Server srv = servers.firstWhere((s) => s.id == evt.serverId);
        srv.isBusy = false;
        srv.customerId = null;
        completed.add(evt.customer);

        if (queue.isNotEmpty) {
          Customer nextC;

          if (_priorityRule == PriorityRule.FIFO) {
            nextC = queue.removeAt(0);
          } else if (_priorityRule == PriorityRule.LIFO) {
            nextC = queue.removeLast();
          } else {
            // SJF
            queue.sort(
              (a, b) => a.serviceDuration.compareTo(b.serviceDuration),
            );
            nextC = queue.removeAt(0);
          }

          srv.isBusy = true;
          srv.customerId = nextC.id;
          nextC.startTime = currentTime;
          totalDelay += (nextC.startTime! - nextC.arrivalTime);

          double depTime = currentTime + nextC.serviceDuration;
          eventList.add(SimEvent(depTime, 'DEP', nextC, serverId: srv.id));
        }
      }

      // Log Row
      String serverStr = servers
          .map((s) => s.isBusy ? "[${s.customerId}]" : "[_]")
          .join();
      String qStr = "[${queue.map((c) => c.id).join(',')}]";
      rows.add(
        TableRowData(
          currentTime.toStringAsFixed(2),
          evt.type,
          "C${evt.customer.id}",
          serverStr,
          queue.length,
          qStr,
          totalDelay.toStringAsFixed(2),
          areaQ.toStringAsFixed(2),
          areaB.toStringAsFixed(2),
        ),
      );
    }

    // 4. Finalize
    double finalTime = currentTime > 0 ? currentTime : 1;
    setState(() {
      _resUtil = (areaB / (numServers * finalTime)) * 100;
      _resLen = areaQ / finalTime;
      _resAreaQ = areaQ;
      _resWait = completed.isNotEmpty ? (totalDelay / completed.length) : 0;
      _chartData = historyQ;
      _tableRows = rows;
      _hasRun = true;
    });
  }

  // --- UI Components ---
  Widget _buildInputLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(
        label,
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, {int lines = 1}) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontFamily: 'Consolas', color: Colors.white),
      keyboardType: lines == 1
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.multiline,
      maxLines: lines,
      decoration: InputDecoration(
        filled: true,
        fillColor: const Color(0xFF2C2C2C),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: Color(0xFF444444)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: kAccentColor),
        ),
      ),
    );
  }

  Widget _buildStatCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        border: Border.all(color: kBorderColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: kAccentColor,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // --- Responsive UI ---
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBgColor,
        title: const Text(
          "Robust Queue Sim",
          style: TextStyle(color: kAccentColor, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              "Mobile Version",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- INPUT PANEL ---
            Container(
              decoration: BoxDecoration(
                color: kCardBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kBorderColor),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TabBar(
                    controller: _tabController,
                    indicatorColor: kAccentColor,
                    labelColor: kAccentColor,
                    unselectedLabelColor: Colors.grey,
                    onTap: (index) => setState(() {}),
                    tabs: const [
                      Tab(text: "Probabilistic"),
                      Tab(text: "Trace Data"),
                    ],
                  ),
                  const SizedBox(height: 16),

                  if (_tabController.index == 0) ...[
                    _buildInputLabel("Number of Servers (c)"),
                    _buildTextField(_cServers),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildInputLabel("Arrival (\u03BB)"),
                              _buildTextField(_cLambda),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildInputLabel("Service (\u03BC)"),
                              _buildTextField(_cMu),
                            ],
                          ),
                        ),
                      ],
                    ),
                    _buildInputLabel("Max Time"),
                    _buildTextField(_cMaxTime),
                    _buildInputLabel("Priority Rule"),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2C),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFF444444)),
                      ),
                      child: DropdownButton<PriorityRule>(
                        value: _priorityRule,
                        dropdownColor: const Color(0xFF2C2C2C),
                        isExpanded: true,
                        underline: Container(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'Consolas',
                        ),
                        items: PriorityRule.values.map((PriorityRule rule) {
                          return DropdownMenuItem<PriorityRule>(
                            value: rule,
                            child: Text(rule.toString().split('.').last),
                          );
                        }).toList(),
                        onChanged: (val) =>
                            setState(() => _priorityRule = val!),
                      ),
                    ),
                  ] else ...[
                    _buildInputLabel("Number of Servers (c)"),
                    _buildTextField(_cManualServers),
                    _buildInputLabel("Trace Data (Arrival, Duration)"),
                    _buildTextField(_cManualData, lines: 6),
                  ],

                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kAccentColor,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: runSimulation,
                      child: const Text(
                        "RUN SIMULATION",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // --- RESULTS PANEL ---
            if (_hasRun) ...[
              Container(
                decoration: BoxDecoration(
                  color: kCardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kBorderColor),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Stats Grid
                    GridView.count(
                      crossAxisCount: 2,
                      // 2 cols for mobile
                      shrinkWrap: true,
                      childAspectRatio: 2.5,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _buildStatCard(
                          "Utilization (\u03C1)",
                          "${_resUtil.toStringAsFixed(1)}%",
                        ),
                        _buildStatCard(
                          "Avg Wait (Wq)",
                          _resWait.toStringAsFixed(3),
                        ),
                        _buildStatCard(
                          "Avg Queue (Lq)",
                          _resLen.toStringAsFixed(3),
                        ),
                        _buildStatCard(
                          "Area Q(t)",
                          _resAreaQ.toStringAsFixed(2),
                        ),
                      ],
                    ),

                    const SizedBox(height: 25),

                    // Chart
                    SizedBox(
                      height: 200,
                      child: LineChart(
                        LineChartData(
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            getDrawingHorizontalLine: (val) => const FlLine(
                              color: Color(0xFF333333),
                              strokeWidth: 1,
                            ),
                          ),
                          titlesData: const FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 30,
                                interval: 1,
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 30,
                              ),
                            ),
                            topTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            rightTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                          lineBarsData: [
                            LineChartBarData(
                              spots: _chartData,
                              isCurved: false,
                              color: kAccentColor,
                              barWidth: 2,
                              isStrokeCapRound: true,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(
                                show: true,
                                color: kAccentColor.withOpacity(0.1),
                              ),
                              // Stepped line effect
                              isStepLineChart: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      "Queue Length Q(t)",
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),

                    const Divider(color: kBorderColor, height: 40),

                    // Table
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Simulation Table",
                        style: TextStyle(
                          color: kAccentColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowColor: MaterialStateProperty.all(
                          const Color(0xFF252525),
                        ),
                        dataRowMinHeight: 30,
                        dataRowMaxHeight: 40,
                        columnSpacing: 20,
                        columns: const [
                          DataColumn(
                            label: Text(
                              'Clock',
                              style: TextStyle(color: kAccentColor),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Event',
                              style: TextStyle(color: kAccentColor),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'ID',
                              style: TextStyle(color: kAccentColor),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Servers',
                              style: TextStyle(color: kAccentColor),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              '#Q',
                              style: TextStyle(color: kAccentColor),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Queue',
                              style: TextStyle(color: kAccentColor),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'TotDelay',
                              style: TextStyle(color: kAccentColor),
                            ),
                          ),
                        ],
                        rows: _tableRows.map((r) {
                          Color typeColor = r.type == 'ARR'
                              ? kAccentColor
                              : (r.type == 'DEP'
                                    ? kSecondaryColor
                                    : Colors.grey);
                          return DataRow(
                            cells: [
                              DataCell(Text(r.clock)),
                              DataCell(
                                Text(
                                  r.type,
                                  style: TextStyle(
                                    color: typeColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              DataCell(Text(r.id)),
                              DataCell(
                                Text(
                                  r.servers,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                              DataCell(Text(r.qLen.toString())),
                              DataCell(
                                Text(
                                  r.qStr,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                              DataCell(Text(r.delay)),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
