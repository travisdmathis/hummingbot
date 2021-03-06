# distutils: language=c++

import time

import pandas as pd
from typing import (
    List
)
from wings.events import MarketEvent
from wings.event_listener cimport EventListener
from wings.market.market_base import (
    MarketBase,
    OrderType
)
from wings.order_book import OrderBook
from hummingbot.strategy.strategy_base import StrategyBase
from .arbitrage_market_pair import ArbitrageMarketPair
from hummingbot.cli.utils.exchange_rate_conversion import ExchangeRateConversion
import logging

NaN = float("nan")
as_logger = None

cdef class BaseArbitrageStrategyEventListener(EventListener):
    cdef:
        ArbitrageStrategy _owner

    def __init__(self, ArbitrageStrategy owner):
        super().__init__()
        self._owner = owner

cdef class BuyOrderCompletedListener(BaseArbitrageStrategyEventListener):
    cdef c_call(self, object arg):
        self._owner.c_did_complete_buy_order(arg)


cdef class SellOrderCompletedListener(BaseArbitrageStrategyEventListener):
    cdef c_call(self, object arg):
        self._owner.c_did_complete_sell_order(arg)


cdef class OrderFailedListener(BaseArbitrageStrategyEventListener):
    cdef c_call(self, object arg):
        self._owner.c_did_fail_order(arg)

cdef class OrderCancelledListener(BaseArbitrageStrategyEventListener):
    cdef c_call(self, object arg):
        self._owner.c_did_cancel_order(arg)

cdef class ArbitrageStrategy(StrategyBase):
    BUY_ORDER_COMPLETED_EVENT_TAG = MarketEvent.BuyOrderCompleted.value
    SELL_ORDER_COMPLETED_EVENT_TAG = MarketEvent.SellOrderCompleted.value
    TRANSACTION_FAILURE_EVENT_TAG = MarketEvent.TransactionFailure.value
    ORDER_CANCELLED_EVENT_TAG = MarketEvent.OrderCancelled.value

    OPTION_LOG_STATUS_REPORT = 1 << 0
    OPTION_LOG_CREATE_ORDER = 1 << 1
    OPTION_LOG_ORDER_COMPLETED = 1 << 2
    OPTION_LOG_PROFITABILITY_STEP = 1 << 3
    OPTION_LOG_FULL_PROFITABILITY_STEP = 1 << 4
    OPTION_LOG_INSUFFICIENT_ASSET = 1 << 5
    OPTION_LOG_ALL = 0xfffffffffffffff
    MARKET_ORDER_MAX_TRACKING_TIME = 60.0 * 10

    @classmethod
    def logger(cls):
        global as_logger
        if as_logger is None:
            as_logger = logging.getLogger(__name__)
        return as_logger

    def __init__(self,
                 market_pairs: List[ArbitrageMarketPair],
                 min_profitability: float,
                 logging_options: int = OPTION_LOG_ORDER_COMPLETED,
                 status_report_interval: float = 900,
                 next_trade_delay_interval: float = 15.0):

        if len(market_pairs) < 0:
            raise ValueError(f"market_pairs must not be empty.")
        super().__init__()
        self._logging_options = logging_options
        self._market_pairs = market_pairs
        self._min_profitability = min_profitability
        self._buy_order_completed_listener = BuyOrderCompletedListener(self)
        self._sell_order_completed_listener = SellOrderCompletedListener(self)
        self._order_failed_listener = OrderFailedListener(self)
        self._order_canceled_listener = OrderCancelledListener(self)
        self._all_markets_ready = False
        self._markets = set()
        self._order_id_to_market = {}
        self._tracked_market_orders = {}
        self._status_report_interval = status_report_interval
        self._last_timestamp = 0
        self._next_trade_delay = next_trade_delay_interval
        self._last_trade_timestamps = {}
        self.exchange_rate_conversion = ExchangeRateConversion.get_instance()

        cdef:
            MarketBase typed_market

        for market_pair in self._market_pairs:
            for market in [market_pair.market_1, market_pair.market_2]:
                self._markets.add(market)
                typed_market = market
                typed_market.c_add_listener(self.SELL_ORDER_COMPLETED_EVENT_TAG, self._sell_order_completed_listener)
                typed_market.c_add_listener(self.BUY_ORDER_COMPLETED_EVENT_TAG, self._buy_order_completed_listener)
                typed_market.c_add_listener(self.TRANSACTION_FAILURE_EVENT_TAG, self._order_failed_listener)
                typed_market.c_add_listener(self.ORDER_CANCELLED_EVENT_TAG, self._order_canceled_listener)

    @property
    def active_markets(self) -> List[MarketBase]:
        return list(self._markets)

    def format_status(self) -> str:
        cdef:
            MarketBase market_1
            MarketBase market_2
            OrderBook market_1_ob
            OrderBook market_2_ob
            str market_1_symbol
            str market_1_base
            str market_1_quote
            str market_2_symbol
            str market_2_base
            str market_2_quote
            double max_profitability
            double market1_base_balance
            double market1_quote_balance
            double market2_base_balance
            double market2_quote_balance
            list lines = []
            list warning_lines = []

        for market_pair in self._market_pairs:
            market_1 = market_pair.market_1
            market_2 = market_pair.market_2

            market_1_symbol = market_pair.market_1_symbol
            market_1_base = market_pair.market_1_base_currency
            market_1_quote = market_pair.market_1_quote_currency
            market_1_ob = market_1.c_get_order_book(market_1_symbol)
            market_2_symbol = market_pair.market_2_symbol
            market_2_base = market_pair.market_2_base_currency
            market_2_quote = market_pair.market_2_quote_currency
            market_2_ob = market_2.c_get_order_book(market_2_symbol)

            market_1_bid_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_1_quote_currency, market_1_ob.get_price(False))

            market_1_ask_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_1_quote_currency, market_1_ob.get_price(True))

            market_2_bid_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_2_quote_currency, market_2_ob.get_price(False))

            market_2_ask_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_2_quote_currency, market_2_ob.get_price(True))

            profitability_buy_market_2_sell_market_1 = market_1_bid_price/market_2_ask_price
            profitability_buy_market_1_sell_market_2 = market_2_bid_price/market_1_ask_price

            max_profitability = max(profitability_buy_market_2_sell_market_1,
                                    profitability_buy_market_1_sell_market_2)
            lines.extend([
                f"{market_1.__class__.__name__}:{market_1_symbol} vs. {market_2.__class__.__name__}:{market_2_symbol}:",
                f"  {market_1_symbol} bid/ask: {market_1_ob.get_price(False)}/{market_1_ob.get_price(True)}",
                f"  {market_2_symbol} bid/ask: {market_2_ob.get_price(False)}/{market_2_ob.get_price(True)}",
                f"  Max profitability: {(max_profitability - 1)*100} %",
                f"  Profitable: {max_profitability - 1 > self._min_profitability}",
                f"  {market_1_base}/{market_1_quote} balance: "
                    f"{market_1.get_balance(market_1_base)}/{market_1.get_balance(market_1_quote)}",
                f"  {market_2_base}/{market_2_quote} balance: "
                    f"{market_2.get_balance(market_2_base)}/{market_2.get_balance(market_2_quote)}"
            ])
            market_1_quote_adjusted = self.exchange_rate_conversion.adjust_token_rate(market_1_quote, 1.0)
            market_2_quote_adjusted = self.exchange_rate_conversion.adjust_token_rate(market_2_quote, 1.0)
            if market_1_quote_adjusted != 1.0 or market_2_quote_adjusted != 1.0:
                lines.extend([
                    f"  Stable Coin Exchange Rate Conversion:",
                    f"      {market_1_quote}: {market_1_quote_adjusted}",
                    f"      {market_2_quote}: {market_2_quote_adjusted}"
                ])

            # See if there're any pending market orders.
            if self._tracked_market_orders:
                pending_orders = [[
                    k[0].__class__.__name__, k[1], v[0], v[1],
                    pd.Timestamp(v[2], unit='s', tz='UTC').strftime('%Y-%m-%d %H:%M:%S')
                ] for k,v in self._tracked_market_orders.items()]

                pending_orders_df = pd.DataFrame(
                    data=pending_orders, columns=["market", "symbol", "order_id", "quantity", "timestamp"])
                df_lines = str(pending_orders_df).split("\n")
                lines.extend(["", "  Pending market orders:"] +
                             ["    " + line for line in df_lines])
            else:
                lines.extend(["", "  No pending market orders."])

            # Add warning lines on null balances.
            if market1_base_balance <= 0:
                warning_lines.append(f"  Primary market {market_1_base} balance is 0. Cannot place order.")
            if market1_quote_balance <= 0:
                warning_lines.append(f"  Primary market {market_1_quote} balance is 0. Cannot place order.")
            if market2_base_balance <= 0:
                warning_lines.append(f"  Secondary market {market_2_base} balance is 0. Cannot place order.")
            if market2_quote_balance <= 0:
                warning_lines.append(f"  Secondary market {market_2_quote} balance is 0.Cannot place order.")

        if len(warning_lines) > 0:
            lines.extend(["", "*** WARNINGS ***"] + warning_lines)

        return "\n".join(lines)


    cdef c_tick(self, double timestamp):
        StrategyBase.c_tick(self, timestamp)

        if not self._all_markets_ready:
            self._all_markets_ready = all([market.ready for market in self._markets])
            if not self._all_markets_ready:
                # Markets not ready yet. Don't do anything.
                return

        for market_pair in self._market_pairs:
            self.c_process_market_pair(market_pair)

        cdef:
            int64_t current_tick
            int64_t last_tick

        if self._logging_options & self.OPTION_LOG_STATUS_REPORT:
            current_tick = <int64_t>(timestamp // self._status_report_interval)
            last_tick = <int64_t>(self._last_timestamp // self._status_report_interval)
            if current_tick < last_tick:
                self.logger().info(self.format_status())

        self._last_timestamp = timestamp

    cdef c_did_complete_buy_order(self, object buy_order_completed_event):
        cdef:
            str order_id = buy_order_completed_event.order_id
            object market_pair = self._order_id_to_market.get(order_id)
        if market_pair is not None:
            if self._logging_options & self.OPTION_LOG_ORDER_COMPLETED:
                self.log_with_clock(
                    logging.INFO,
                    f"Market order completed on {market_pair[0].__class__.__name__}: {order_id}"
                )
            del self._order_id_to_market[order_id]
            if market_pair in self._tracked_market_orders:
                del self._tracked_market_orders[market_pair]


    cdef c_did_complete_sell_order(self, object sell_order_completed_event):
        cdef:
            str order_id = sell_order_completed_event.order_id
            object market_pair = self._order_id_to_market.get(order_id)
        if market_pair is not None:
            if self._logging_options & self.OPTION_LOG_ORDER_COMPLETED:
                self.log_with_clock(
                    logging.INFO,
                    f"Market order completed on {market_pair[0].__class__.__name__}: {order_id}"
                )
            del self._order_id_to_market[order_id]
            if market_pair in self._tracked_market_orders:
                del self._tracked_market_orders[market_pair]

    cdef c_did_fail_order(self, object fail_event):
        cdef:
            object market_pair = self._order_id_to_market.get(fail_event.order_id)

        if market_pair is not None:
            self.log_with_clock(
                logging.INFO,
                f"Market order failed on {market_pair[0].__class__.__name__}: {fail_event.order_id}"
            )
            del self._order_id_to_market[fail_event.order_id]
            if market_pair in self._tracked_market_orders:
                del self._tracked_market_orders[market_pair]

    cdef c_did_cancel_order(self, object cancel_event):
        cdef:
            object market_pair = self._order_id_to_market.get(cancel_event.order_id)

        if market_pair is not None:
            self.log_with_clock(
                logging.INFO,
                f"Market order canceled on {market_pair[0].__class__.__name__}: {cancel_event.order_id}"
            )
            del self._order_id_to_market[cancel_event.order_id]
            if market_pair in self._tracked_market_orders:
                del self._tracked_market_orders[market_pair]

    cdef c_process_market_pair(self, object market_pair):
        """
        Execute strategy for market paris
        :param market_pair: 
        :return: 
        """
        cdef:
            MarketBase market_1 = market_pair.market_1
            MarketBase market_2 = market_pair.market_2
            OrderBook order_book_1 = market_1.c_get_order_book(market_pair.market_1_symbol)
            OrderBook order_book_2 = market_2.c_get_order_book(market_pair.market_2_symbol)

            double market_1_bid_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_1_quote_currency, order_book_1.get_price(False))

            double market_1_ask_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_1_quote_currency, order_book_1.get_price(True))

            double market_2_bid_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_2_quote_currency, order_book_2.get_price(False))

            double market_2_ask_price = self.exchange_rate_conversion.adjust_token_rate(
                market_pair.market_2_quote_currency, order_book_2.get_price(True))

        profitability_buy_market_2_sell_market_1 = market_1_bid_price/market_2_ask_price
        profitability_buy_market_1_sell_market_2 = market_2_bid_price/market_1_ask_price

        if profitability_buy_market_1_sell_market_2 > profitability_buy_market_2_sell_market_1:
            # it is more profitable to buy on market_1 and sell on market_2
            self.c_process_market_pair_inner(
                market_pair.market_1,
                market_pair.market_1_symbol,
                market_pair.market_1_base_currency,
                market_pair.market_1_quote_currency,
                order_book_1,
                market_pair.market_2,
                market_pair.market_2_symbol,
                market_pair.market_2_base_currency,
                market_pair.market_2_quote_currency,
                order_book_2
            )

        else:
            self.c_process_market_pair_inner(
                market_pair.market_2,
                market_pair.market_2_symbol,
                market_pair.market_2_base_currency,
                market_pair.market_2_quote_currency,
                order_book_2,
                market_pair.market_1,
                market_pair.market_1_symbol,
                market_pair.market_1_base_currency,
                market_pair.market_1_quote_currency,
                order_book_1
            )

    cdef c_process_market_pair_inner(self,
                                     MarketBase buy_market,
                                     str buy_market_symbol,
                                     str buy_market_base_currency,
                                     str buy_market_quote_currency,
                                     OrderBook buy_order_book,
                                     MarketBase sell_market,
                                     str sell_market_symbol,
                                     str sell_market_base_currency,
                                     str sell_market_quote_currency,
                                     OrderBook sell_order_book
                                     ):
        """        
        Execute strategy for market paris
        :param buy_market: 
        :param buy_market_symbol: 
        :param buy_market_base_currency: 
        :param buy_market_quote_currency: 
        :param buy_order_book: 
        :param sell_market: 
        :param sell_market_symbol: 
        :param sell_market_base_currency: 
        :param sell_market_quote_currency: 
        :param sell_order_book: 
        :return: 
        """
        cdef:
            double total_bid_value = 0 # total revenue
            double total_ask_value = 0 # total cost
            double total_bid_value_adjusted = 0 # total revenue adjusted with exchange rate conversion
            double total_ask_value_adjusted = 0 # total cost adjusted with exchange rate conversion
            double total_profitable_base_amount = 0
            double final_profitability = 0
            double profitability
            double buy_market_quote_asset
            double sell_market_base_asset
            tuple buy_market_key = (buy_market, buy_market_symbol)
            tuple sell_market_key = (sell_market, sell_market_symbol)
            double time_now = time.time()
            double buy_market_size_limit
            double sell_market_size_limit
            double quantized_profitable_base_amount
            str buy_order_id
            str sell_order_id
            object tracked_buy_market_order = self._tracked_market_orders.get(buy_market_key)
            object tracked_sell_market_order = self._tracked_market_orders.get(sell_market_key)
            double time_left

        # Do not continue if there are pending market order on buy market
        if tracked_buy_market_order is not None:
            # consider market order completed if it was already x time old
            if tracked_buy_market_order[1] - time_now > self.MARKET_ORDER_MAX_TRACKING_TIME:
                pass
            else:
                return

        # Do not continue if there are pending market order on sell market
        if tracked_sell_market_order is not None:
            # consider market order completed if it was already x time old
            if tracked_sell_market_order[1] - time_now > self.MARKET_ORDER_MAX_TRACKING_TIME:
                pass
            else:
                return

        # Wait for the cool off interval before the next trade, so wallet balance is up to date
        if buy_market_key in self._last_trade_timestamps and \
                self._last_trade_timestamps[buy_market_key] + self._next_trade_delay > self._current_timestamp:
            time_left = self._current_timestamp - self._last_trade_timestamps[buy_market_key] - self._next_trade_delay
            self.log_with_clock(
                logging.INFO,
                f"Cooling off from previous trade on {buy_market.__class__.__name__}:{buy_market_symbol}. "
                f"Resuming in {int(time_left)} seconds."
                )
            return

        if sell_market_key in self._last_trade_timestamps and \
                self._last_trade_timestamps[sell_market_key] + self._next_trade_delay > self._current_timestamp:
            time_left = self._current_timestamp - self._last_trade_timestamps[sell_market_key] - self._next_trade_delay
            self.log_with_clock(
                logging.INFO,
                f"Cooling off from previous trade on {sell_market.__class__.__name__}:{sell_market_symbol}. "
                f"Resuming in {int(time_left)} seconds."
                )
            return

        profitable_orders = self.c_find_profitable_arbitrage_orders(self._min_profitability,
                                                                    buy_order_book,
                                                                    sell_order_book,
                                                                    buy_market_quote_currency,
                                                                    sell_market_quote_currency)
        # see if each step meets the profit level, and is within the wallet balance
        for bid_price_adjusted, ask_price_adjusted, bid_price, ask_price, amount in profitable_orders:
            # accumulated profitability
            profitability = (total_bid_value_adjusted + bid_price_adjusted * amount) / \
                            (total_ask_value_adjusted + ask_price_adjusted * amount)

            buy_market_quote_asset = buy_market.c_get_balance(buy_market_quote_currency)
            sell_market_base_asset = sell_market.c_get_balance(sell_market_base_currency)

            # stop current step if profitability is lower than desired
            if profitability < (1 + self._min_profitability):
                break

            if self._logging_options & self.OPTION_LOG_PROFITABILITY_STEP:
                self.log_with_clock(logging.DEBUG, f"Total profitability: {profitability}, "
                                                   f"Current step profitability: {bid_price/ask_price},"
                                                   f"bid, ask price, amount: {bid_price, ask_price, amount}")

            # stop current step if buy/sell market does not have enough asset
            if buy_market_quote_asset < (total_ask_value + ask_price * amount) or \
                    sell_market_base_asset < (total_profitable_base_amount + amount):

                if self._logging_options & self.OPTION_LOG_INSUFFICIENT_ASSET:
                    self.log_with_clock(logging.DEBUG,
                                    f"Not enough asset to complete this step. "
                                    f"Quote asset needed: {total_ask_value + ask_price * amount}. "
                                    f"Quote asset balance: {buy_market_quote_asset}. "
                                    f"Base asset needed: {total_bid_value + bid_price * amount}. "
                                    f"Base asset balance: {sell_market_base_asset}. ")

                # buy and sell with the amount of available base or quote asset, whichever is smaller
                total_profitable_base_amount = min(sell_market_base_asset,
                                                   buy_market_quote_asset/ask_price)
                final_profitability = profitability

                break

            total_bid_value += bid_price * amount
            total_ask_value += ask_price * amount
            total_bid_value_adjusted += bid_price_adjusted * amount
            total_ask_value_adjusted += ask_price_adjusted * amount
            total_profitable_base_amount += amount
            final_profitability = profitability

        buy_market_size_limit = buy_market.c_quantize_order_amount(buy_market_symbol,
                                                                   total_profitable_base_amount)
        sell_market_size_limit = sell_market.c_quantize_order_amount(sell_market_symbol,
                                                                     total_profitable_base_amount)
        quantized_profitable_base_amount = min(buy_market_size_limit, sell_market_size_limit)

        if quantized_profitable_base_amount:
            if self._logging_options & self.OPTION_LOG_CREATE_ORDER:
                self.log_with_clock(logging.INFO,
                                    f"Executing market order buy of {buy_market_symbol} "
                                    f"at {buy_market.__class__.__name__} "
                                    f"and sell of {sell_market_symbol} "
                                    f"at {sell_market.__class__.__name__} "
                                    f"with amount {quantized_profitable_base_amount}, "
                                    f"and profitability {final_profitability}")

            if self._logging_options & self.OPTION_LOG_FULL_PROFITABILITY_STEP:
                self.log_with_clock(logging.DEBUG,
                    "\n" + pd.DataFrame(
                        data=[
                            [b_price/a_price, b_price, a_price, amount]
                            for b_price, a_price, amount in profitable_orders],
                        columns=['raw_profitability', 'bid_price', 'ask_price', 'step_amount']
                    ).to_string()
                )

            buy_order_id = self.c_buy_with_specific_market(
                buy_market,
                buy_market_symbol,
                quantized_profitable_base_amount,
                order_type=OrderType.MARKET
            )
            sell_order_id = self.c_sell_with_specific_market(
                sell_market,
                sell_market_symbol,
                quantized_profitable_base_amount,
                order_type=OrderType.MARKET
            )

            time_now = self._current_timestamp
            self._last_trade_timestamps[buy_order_id] = time_now
            self._last_trade_timestamps[sell_order_id] = time_now
            self._order_id_to_market[buy_order_id] = buy_market_key
            self._order_id_to_market[sell_order_id] = sell_market_key
            self._tracked_market_orders[buy_market_key] = (
                buy_order_id, quantized_profitable_base_amount, time_now
            )
            self._tracked_market_orders[sell_market_key] = (
                sell_order_id, quantized_profitable_base_amount, time_now
            )
            self.logger().info(self.format_status())

    def log_with_clock(self, log_level: int, msg: str):
        clock_timestamp = pd.Timestamp(self._current_timestamp, unit="s", tz="UTC")
        self.logger().log(log_level, f"{msg} [clock={str(clock_timestamp)}]")

    cdef c_buy_with_specific_market(self, MarketBase market, str symbol, double amount,
                                    object order_type = OrderType.MARKET, double price = 0.0):
        if market not in self._markets:
            raise ValueError(f"market object for buy order is not in the whitelisted markets set.")
        return market.c_buy(symbol, amount, order_type=order_type, price=price)

    cdef c_sell_with_specific_market(self, MarketBase market, str symbol, double amount,
                                     object order_type = OrderType.MARKET, double price = 0.0):
        if market not in self._markets:
            raise ValueError(f"market object for sell order is not in the whitelisted markets set.")
        return market.c_sell(symbol, amount, order_type=order_type, price=price)

    @classmethod
    def find_profitable_arbitrage_orders(cls,
                                         min_profitability,
                                         sell_order_book: OrderBook,
                                         buy_order_book: OrderBook,
                                         buy_market_quote_currency,
                                         sell_market_quote_currency):
        return cls.c_find_profitable_arbitrage_orders(min_profitability,
                                                      sell_order_book,
                                                      buy_order_book,
                                                      buy_market_quote_currency,
                                                      sell_market_quote_currency)

    cdef list c_find_profitable_arbitrage_orders(self,
                                                 double min_profitability,
                                                 OrderBook buy_order_book,
                                                 OrderBook sell_order_book,
                                                 str buy_market_quote_currency,
                                                 str sell_market_quote_currency):
        """
        :param sell_order_book: 
        :param buy_order_book: 
        :return: bid_price, ask_price, amount
        """
        cdef:
            double step_amount = 0
            double bid_leftover_amount = 0
            double ask_leftover_amount = 0
            object current_bid = None
            object current_ask = None
            double current_bid_price_adjusted
            double current_ask_price_adjusted

        profitable_orders = []
        bid_it = sell_order_book.bid_entries()
        ask_it = buy_order_book.ask_entries()
        try:
            while True:
                if bid_leftover_amount == 0 and ask_leftover_amount == 0:
                    # both current ask and bid orders are filled, advance to the next bid and ask order
                    current_bid = next(bid_it)
                    current_ask = next(ask_it)
                    ask_leftover_amount = current_ask.amount
                    bid_leftover_amount = current_bid.amount

                elif bid_leftover_amount > 0 and ask_leftover_amount == 0:
                    # current ask order filled completely, advance to the next ask order
                    current_ask = next(ask_it)
                    ask_leftover_amount = current_ask.amount

                elif ask_leftover_amount > 0 and bid_leftover_amount == 0:
                    # current bid order filled completely, advance to the next bid order
                    current_bid = next(bid_it)
                    bid_leftover_amount = current_bid.amount

                elif bid_leftover_amount > 0 and ask_leftover_amount > 0:
                    # current ask and bid orders are not completely filled, no need to advance iterators
                    pass
                else:
                    # something went wrong if leftover amount is negative
                    break

                # adjust price based on the quote token rates
                current_bid_price_adjusted = self.exchange_rate_conversion.adjust_token_rate(sell_market_quote_currency,
                                                                                             current_bid.price)
                current_ask_price_adjusted = self.exchange_rate_conversion.adjust_token_rate(buy_market_quote_currency,
                                                                                             current_ask.price)
                # arbitrage not possible
                if current_bid_price_adjusted/current_ask_price_adjusted < (1 + min_profitability):
                    break

                step_amount = min(bid_leftover_amount, ask_leftover_amount)
                profitable_orders.append((current_bid_price_adjusted,
                                          current_ask_price_adjusted,
                                          current_bid.price,
                                          current_ask.price,
                                          step_amount))

                ask_leftover_amount -= step_amount
                bid_leftover_amount -= step_amount


        except StopIteration:
            pass

        return profitable_orders
