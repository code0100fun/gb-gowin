#pragma once

#include <verilated.h>
#include <verilated_vcd_c.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

// Simple testbench wrapper for Verilator modules.
//
// Usage:
//   #include "testbench.h"
//   #include "Vblinky.h"
//
//   int main(int argc, char** argv) {
//       Testbench<Vblinky> tb("blinky.vcd");
//       tb.reset();            // optional: hold rst high for 5 cycles
//       tb.tick();             // one clock cycle
//       tb.tick(100);          // 100 clock cycles
//       assert(tb.dut->led);   // check outputs
//       tb.pass("LED test");   // report pass
//       return tb.done();
//   }
template <typename DUT>
class Testbench {
   public:
    DUT* dut;

    Testbench(const std::string& trace_file = "", int argc = 0,
              char** argv = nullptr) {
        Verilated::commandArgs(argc, argv);
        Verilated::traceEverOn(true);

        dut = new DUT;
        m_trace = nullptr;
        m_tickcount = 0;
        m_pass_count = 0;
        m_fail_count = 0;

        if (!trace_file.empty()) {
            m_trace = new VerilatedVcdC;
            dut->trace(m_trace, 99);
            m_trace->open(trace_file.c_str());
        }

        // Initial eval to establish signal states before the first clock edge.
        // Without this, Verilator may not detect the first posedge properly.
        dut->clk = 0;
        dut->eval();
        if (m_trace) m_trace->dump(0);
    }

    ~Testbench() {
        if (m_trace) {
            m_trace->close();
            delete m_trace;
        }
        delete dut;
    }

    // Advance simulation by one clock cycle (rising edge + falling edge).
    void tick() {
        // Rising edge
        dut->clk = 1;
        dut->eval();
        if (m_trace) m_trace->dump(m_tickcount * 10 + 5);

        // Falling edge
        dut->clk = 0;
        dut->eval();
        if (m_trace) m_trace->dump(m_tickcount * 10 + 10);

        m_tickcount++;
    }

    // Advance simulation by n clock cycles.
    void tick(uint64_t n) {
        for (uint64_t i = 0; i < n; i++) tick();
    }

    // Hold rst high for n cycles, then release. Does nothing if the DUT has
    // no rst port (but the DUT must have a clk port).
    template <typename T = DUT>
    auto reset(int cycles = 5)
        -> decltype(std::declval<T>().rst, void()) {
        dut->rst = 1;
        tick(cycles);
        dut->rst = 0;
        tick(1);
    }

    // Current simulation time in clock cycles.
    uint64_t time() const { return m_tickcount; }

    // Test assertion helpers.
    void check(bool condition, const std::string& msg) {
        if (condition) {
            m_pass_count++;
        } else {
            m_fail_count++;
            printf("  FAIL: %s (at tick %lu)\n", msg.c_str(), m_tickcount);
        }
    }

    void pass(const std::string& msg) {
        m_pass_count++;
        printf("  PASS: %s\n", msg.c_str());
    }

    // Call at the end of the testbench. Returns 0 if all tests passed, 1
    // otherwise.
    int done() {
        printf("\n--- Results: %d passed, %d failed ---\n", m_pass_count,
               m_fail_count);
        if (m_trace) m_trace->flush();
        return m_fail_count > 0 ? 1 : 0;
    }

   private:
    VerilatedVcdC* m_trace;
    uint64_t m_tickcount;
    int m_pass_count;
    int m_fail_count;
};
